import AVFoundation
import CoreImage

/// Everything needed to render a post, independent of the UI.
struct RenderJob {
    var style: StyleSettings
    var mode: LayoutMode
    /// Active slots (1 for single, 2 for compare).
    var slots: [MediaItem?]
    var offsets: [Double] = [0, 0]
    var zooms: [ZoomSegment] = []
    /// Portion of the timeline to export (nil = everything).
    var trim: ClosedRange<Double>?
    /// Per-slot speed changes (speed setting + sped-up pauses).
    var timeMaps: [TimeMap?] = []

    var hasVideo: Bool { slots.contains { $0?.isVideo == true } }
    /// Tours are always videos (the camera moves), even when made only of screenshots.
    var producesVideo: Bool { hasVideo || (mode == .tour && slots.compactMap { $0 }.count > 0) }
    var tour: TourPlan? { mode == .tour ? TourPlan.make(items: slots, offsets: offsets, timeMaps: timeMaps) : nil }

    func renderParams(canvasSize: CGSize, zoomEnabled: Bool = true, placeholders: Bool = false) -> RenderParams {
        let fallback: CGFloat = slots.compactMap { item -> CGFloat? in item?.aspect }.first ?? (9.0 / 20.0)
        let empty = Set(slots.indices.filter { slots[$0] == nil })
        return RenderParams(
            canvasSize: canvasSize,
            style: style,
            mode: mode,
            aspects: slots.map { item -> CGFloat in item.map { $0.aspect } ?? fallback },
            stills: slots.map { $0?.still },
            placeholders: placeholders ? empty : [],
            zooms: zooms,
            zoomEnabled: zoomEnabled,
            tour: tour,
            crops: slots.map { $0?.cropTop ?? 0 },
            clicks: clickMarks()
        )
    }

    /// Recorded clicks in output time (after trimming, speed changes and tour timing), on the visible content.
    func clickMarks() -> [[ClickMark]] {
        let starts = tour?.videoStarts
        return slots.enumerated().map { i, item in
            guard let item, !item.clicks.isEmpty else { return [] }
            let offset = i < offsets.count ? offsets[i] : 0
            let map = i < timeMaps.count ? timeMaps[i] : nil
            let start = starts.flatMap { i < $0.count ? $0[i] : nil } ?? 0
            let crop = Double(item.cropTop)
            return item.clicks.compactMap { c in
                let local = c.t - offset
                let v = (c.v - crop) / max(0.01, 1 - crop)
                guard local >= 0, v >= 0, v <= 1 else { return nil }
                return ClickMark(time: start + (map?.output(at: local) ?? local), u: c.u, v: v)
            }
        }
    }
}

final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var _cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }
    func cancel() { lock.lock(); _cancelled = true; lock.unlock() }
}

enum ExportError: LocalizedError {
    case nothingToExport
    case cancelled
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .nothingToExport: "Add a recording or screenshot first."
        case .cancelled: "Export cancelled."
        case .failed(let message): "Export failed: \(message)"
        }
    }
}

enum ExportEngine {
    // MARK: Still images

    /// Renders screenshots to an sRGB PNG/JPEG at 1× or 2× resolution.
    static func exportStill(job: RenderJob, to url: URL) throws {
        let scale = CGFloat(max(1, job.style.export.imageScale))
        let size = CGSize(width: job.style.canvas.size.width * scale, height: job.style.canvas.size.height * scale)
        let renderer = SceneRenderer(job.renderParams(canvasSize: size, zoomEnabled: false))
        guard let image = renderer.makeCGImage() else { throw ExportError.failed("Couldn't render the image.") }
        try RenderCore.writeImage(image, to: url, format: job.style.export.imageFormat)
    }

    /// Renders one moment of a video post as a high-resolution still (zoom included).
    static func exportFrame(job: RenderJob, time: Double, to url: URL) async throws {
        var frames: [CIImage?] = []
        let starts = job.tour?.videoStarts
        for (i, item) in job.slots.enumerated() {
            guard let item, item.isVideo else { frames.append(nil); continue }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: item.url))
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let offset = i < job.offsets.count ? job.offsets[i] : 0
            // Output time → clip time (tour start, speed changes, then the trimmed-off start).
            var local = max(0, time - (starts.flatMap { i < $0.count ? $0[i] : nil } ?? 0))
            if i < job.timeMaps.count, let map = job.timeMaps[i] { local = map.source(at: local) }
            let t = min(max(0, local + offset), max(0, item.duration - 0.05))
            let (cg, _) = try await generator.image(at: CMTime(seconds: t, preferredTimescale: 600))
            frames.append(CIImage(cgImage: cg, options: [.colorSpace: RenderCore.sRGB]))
        }
        let scale = CGFloat(max(1, job.style.export.imageScale))
        let size = CGSize(width: job.style.canvas.size.width * scale, height: job.style.canvas.size.height * scale)
        let renderer = SceneRenderer(job.renderParams(canvasSize: size))
        guard let image = renderer.makeCGImage(time: time, frames: frames) else { throw ExportError.failed("Couldn't render the frame.") }
        try RenderCore.writeImage(image, to: url, format: job.style.export.imageFormat)
    }

    // MARK: Video

    /// H.264 High profile MP4, BT.709 colour tags, constant frame rate, fast-start: what X handles best.
    static func exportVideo(job: RenderJob, to url: URL, cancel: CancelToken = CancelToken(),
                            progress: @escaping @Sendable (Double) -> Void) async throws {
        guard job.producesVideo else { throw ExportError.nothingToExport }
        let style = job.style
        let size = style.export.videoSize(for: style.canvas)
        let fps = style.export.fps
        let box = RenderBox(SceneRenderer(job.renderParams(canvasSize: size)))
        let tour = job.tour
        let built = try await CompositionBuilder.build(slots: job.slots, offsets: job.offsets, starts: tour?.videoStarts,
                                                       minDuration: tour?.total ?? 0, timeMaps: job.timeMaps,
                                                       includeAudio: style.export.includeAudio,
                                                       renderSize: size, fps: fps, box: box, tagging: .export)

        let lower = max(0, job.trim?.lowerBound ?? 0)
        let upper = min(built.duration, job.trim?.upperBound ?? built.duration)
        guard upper - lower > 0.05 else { throw ExportError.nothingToExport }
        let range = CMTimeRange(start: CMTime(seconds: lower, preferredTimescale: 600), end: CMTime(seconds: upper, preferredTimescale: 600))

        let reader = try AVAssetReader(asset: built.asset)
        reader.timeRange = range
        let videoTracks = try await built.asset.loadTracks(withMediaType: .video)
        let videoOutput = AVAssetReaderVideoCompositionOutput(videoTracks: videoTracks, videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        videoOutput.videoComposition = built.videoComposition
        videoOutput.alwaysCopiesSampleData = false
        reader.add(videoOutput)

        var audioOutput: AVAssetReaderAudioMixOutput?
        let audioTracks = try await built.asset.loadTracks(withMediaType: .audio)
        if style.export.includeAudio && !audioTracks.isEmpty {
            let output = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
            output.audioTimePitchAlgorithm = .spectral  // keep voices natural when sped up
            reader.add(output)
            audioOutput = output
        }

        // High bitrate for a clean master, but capped so 4K stays reasonable and under X's 512 MB limit.
        let durationSeconds = max(1, upper - lower)
        let bitrate = min(style.export.quality.bitrate(size: size, fps: fps), 60_000_000, Int(480_000_000 * 8 / durationSeconds))

        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoH264EntropyModeKey: AVVideoH264EntropyModeCABAC,
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoAllowFrameReorderingKey: true,
            ],
        ])
        videoInput.expectsMediaDataInRealTime = false
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 160_000,
            ])
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audioInput = input
        }

        guard reader.startReading() else { throw ExportError.failed(reader.error?.localizedDescription ?? "Couldn't read the media.") }
        guard writer.startWriting() else { throw ExportError.failed(writer.error?.localizedDescription ?? "Couldn't create the file.") }
        writer.startSession(atSourceTime: range.start)

        let total = range.duration.seconds
        let startSeconds = range.start.seconds

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let group = DispatchGroup()

            func pump(_ input: AVAssetWriterInput, _ output: AVAssetReaderOutput, label: String, reportProgress: Bool) {
                group.enter()
                let finished = OnceFlag()
                input.requestMediaDataWhenReady(on: DispatchQueue(label: "AppX Motion.export.\(label)")) {
                    while input.isReadyForMoreMediaData {
                        if cancel.isCancelled {
                            reader.cancelReading()
                        }
                        guard !cancel.isCancelled, let sample = output.copyNextSampleBuffer() else {
                            input.markAsFinished()
                            if finished.set() { group.leave() }
                            return
                        }
                        if reportProgress {
                            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                            progress(min(1, max(0, (pts - startSeconds) / max(total, 0.001))))
                        }
                        if !input.append(sample) {
                            reader.cancelReading()
                            input.markAsFinished()
                            if finished.set() { group.leave() }
                            return
                        }
                    }
                }
            }

            pump(videoInput, videoOutput, label: "video", reportProgress: true)
            if let audioInput, let audioOutput {
                pump(audioInput, audioOutput, label: "audio", reportProgress: false)
            }

            group.notify(queue: .global()) {
                if cancel.isCancelled {
                    writer.cancelWriting()
                    try? FileManager.default.removeItem(at: url)
                    continuation.resume(throwing: ExportError.cancelled)
                    return
                }
                if reader.status == .failed || writer.status == .failed {
                    let message = writer.error?.localizedDescription ?? reader.error?.localizedDescription ?? "Unknown error"
                    writer.cancelWriting()
                    continuation.resume(throwing: ExportError.failed(message))
                    return
                }
                writer.finishWriting {
                    if writer.status == .completed {
                        progress(1)
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: ExportError.failed(writer.error?.localizedDescription ?? "Couldn't finish the file."))
                    }
                }
            }
        }
    }
}

/// Thread-safe "only once" flag.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    /// Returns true the first time it's called.
    func set() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
