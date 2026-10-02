import AVFoundation
import CoreImage
import QuartzCore

/// Holds the current renderer. The editor swaps in a new one whenever the style changes,
/// and the compositor picks it up on the next frame.
final class RenderBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _renderer: SceneRenderer?

    init(_ renderer: SceneRenderer? = nil) { _renderer = renderer }

    var renderer: SceneRenderer? {
        get { lock.lock(); defer { lock.unlock() }; return _renderer }
        set { lock.lock(); _renderer = newValue; lock.unlock() }
    }
}

final class SceneInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid

    /// Composition track for each phone slot (`kCMPersistentTrackID_Invalid` for screenshots or empty slots).
    let slotTracks: [CMPersistentTrackID]
    let slotOrientations: [CGImagePropertyOrientation]
    let box: RenderBox
    let tagging: RenderCore.Tagging

    init(timeRange: CMTimeRange, slotTracks: [CMPersistentTrackID], slotOrientations: [CGImagePropertyOrientation],
         box: RenderBox, tagging: RenderCore.Tagging) {
        self.timeRange = timeRange
        self.slotTracks = slotTracks
        self.slotOrientations = slotOrientations
        self.box = box
        self.tagging = tagging
        let ids = slotTracks.filter { $0 != kCMPersistentTrackID_Invalid }.map { NSNumber(value: $0) }
        requiredSourceTrackIDs = ids.isEmpty ? nil : ids
    }
}

/// Custom AVFoundation compositor: used for live preview (AVPlayer) and for export (AVAssetReader),
/// so what you see is exactly what gets exported.
final class SceneCompositor: NSObject, AVVideoCompositing {
    private let lock = NSLock()
    private var lastFrames: [Int: CIImage] = [:]

    private static let pixelAttributes: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: any Sendable](),
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]

    var sourcePixelBufferAttributes: [String: any Sendable]? { Self.pixelAttributes }
    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] { Self.pixelAttributes }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        autoreleasepool {
            guard let instruction = request.videoCompositionInstruction as? SceneInstruction,
                  let renderer = instruction.box.renderer,
                  let output = request.renderContext.newPixelBuffer() else {
                request.finish(with: NSError(domain: "AppX Motion", code: 1, userInfo: [NSLocalizedDescriptionKey: "Renderer not ready"]))
                return
            }

            var frames: [CIImage?] = []
            for (slot, trackID) in instruction.slotTracks.enumerated() {
                guard trackID != kCMPersistentTrackID_Invalid else { frames.append(nil); continue }
                if let buffer = request.sourceFrame(byTrackID: trackID) {
                    var image = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: RenderCore.sRGB])
                    if slot < instruction.slotOrientations.count, instruction.slotOrientations[slot] != .up {
                        image = image.oriented(instruction.slotOrientations[slot])
                        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
                    }
                    lock.lock(); lastFrames[slot] = image; lock.unlock()
                    frames.append(image)
                } else {
                    lock.lock(); let cached = lastFrames[slot]; lock.unlock()
                    frames.append(cached)
                }
            }

            let t0 = CACurrentMediaTime()
            var image = renderer.render(time: request.compositionTime.seconds, frames: frames)
            let t1 = CACurrentMediaTime()
            let size = request.renderContext.size
            if size != renderer.canvasSize, renderer.canvasSize.width > 0, renderer.canvasSize.height > 0 {
                image = image.transformed(by: CGAffineTransform(scaleX: size.width / renderer.canvasSize.width,
                                                                y: size.height / renderer.canvasSize.height))
            }
            RenderCore.context.render(image, to: output, bounds: CGRect(origin: .zero, size: size), colorSpace: RenderCore.sRGB)
            RenderCore.tag(output, instruction.tagging)
            request.finish(withComposedVideoFrame: output)
            Profiler.record(scene: t1 - t0, total: CACurrentMediaTime() - t0)
        }
    }

    func cancelAllPendingVideoCompositionRequests() {}
}

/// Opt-in frame timing (`PF_PROFILE=1`).
enum Profiler {
    private static let enabled = ProcessInfo.processInfo.environment["PF_PROFILE"] != nil
    private static let lock = NSLock()
    private static var count = 0, scene = 0.0, total = 0.0
    static func record(scene s: Double, total t: Double) {
        guard enabled else { return }
        lock.lock(); defer { lock.unlock() }
        count += 1; scene += s; total += t
        if count % 60 == 0 {
            print(String(format: "  frames %d · build %.1f ms · build+GPU %.1f ms", count, scene / Double(count) * 1000, total / Double(count) * 1000))
        }
    }
}

// MARK: - Building the AVComposition

struct BuiltComposition {
    let asset: AVComposition
    let videoComposition: AVVideoComposition
    let duration: Double
}

enum CompositionBuilder {
    /// Puts each video slot on its own track starting at time zero (after skipping `offsets[i]` seconds),
    /// and freezes shorter clips on their last frame so both phones stay filled.
    ///   - starts: composition time at which each slot's clip begins (tours); before that its first frame is shown.
    ///   - minDuration: the timeline is at least this long (tours, or screenshot-only videos).
    ///   - timeMaps: per-slot speed changes (nil = real time).
    static func build(slots: [MediaItem?], offsets: [Double], starts: [Double]? = nil, minDuration: Double = 0,
                      timeMaps: [TimeMap?] = [], includeAudio: Bool, renderSize: CGSize,
                      fps: Int, box: RenderBox, tagging: RenderCore.Tagging) async throws -> BuiltComposition {
        let composition = AVMutableComposition()
        var slotTracks = [CMPersistentTrackID](repeating: kCMPersistentTrackID_Invalid, count: slots.count)
        var orientations = [CGImagePropertyOrientation](repeating: .up, count: slots.count)
        var inserted: [(AVMutableCompositionTrack, CMTime)] = []
        var audioAdded = false

        for (i, item) in slots.enumerated() {
            guard let item, item.isVideo else { continue }
            let asset = AVURLAsset(url: item.url)
            guard let source = try await asset.loadTracks(withMediaType: .video).first else { continue }
            let range = try await source.load(.timeRange)
            let offset = CMTime(seconds: max(0, min(i < offsets.count ? offsets[i] : 0, range.duration.seconds - 0.2)), preferredTimescale: 600)
            let usable = CMTimeRange(start: range.start + offset, end: range.end)
            guard usable.duration.seconds > 0.05,
                  let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            let startAt = CMTime(seconds: max(0, starts.flatMap { i < $0.count ? $0[i] : nil } ?? 0), preferredTimescale: 600)
            if startAt.seconds > 0.02 {
                // Hold the first frame until the clip's start time.
                let first = CMTime(value: 1, timescale: 30)
                try track.insertTimeRange(CMTimeRange(start: usable.start, duration: first), of: source, at: .zero)
                track.scaleTimeRange(CMTimeRange(start: .zero, duration: first), toDuration: startAt)
            }
            try track.insertTimeRange(usable, of: source, at: startAt)
            let map = i < timeMaps.count ? timeMaps[i] : nil
            apply(map, to: track, startingAt: startAt)
            slotTracks[i] = track.trackID
            orientations[i] = item.orientation
            inserted.append((track, end(of: track)))

            if includeAudio && !audioAdded, let audioSource = try await asset.loadTracks(withMediaType: .audio).first,
               let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                let audioRange = try await audioSource.load(.timeRange)
                let clipped = CMTimeRange(start: CMTimeMaximum(audioRange.start, usable.start), end: CMTimeMinimum(audioRange.end, usable.end))
                if clipped.duration.seconds > 0 {
                    try audioTrack.insertTimeRange(clipped, of: audioSource, at: startAt + (clipped.start - usable.start))
                    apply(map, to: audioTrack, startingAt: startAt)
                    audioAdded = true
                }
            }
        }

        var total = inserted.map(\.1).reduce(CMTime.zero) { CMTimeMaximum($0, $1) }
        total = CMTimeMaximum(total, CMTime(seconds: minDuration, preferredTimescale: 600))
        guard total.seconds > 0 else { throw MediaError.unsupported("composition") }

        // Screenshot-only timelines are driven by a tiny blank clip stretched to length.
        if inserted.isEmpty {
            let timer = AVURLAsset(url: try await TimerClip.url())
            if let source = try await timer.loadTracks(withMediaType: .video).first,
               let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
                let range = try await source.load(.timeRange)
                try track.insertTimeRange(range, of: source, at: .zero)
                track.scaleTimeRange(CMTimeRange(start: .zero, duration: range.duration), toDuration: total)
            }
        }

        // Hold the last frame of shorter clips.
        for (track, length) in inserted where (total - length).seconds > 0.02 {
            let tail = CMTime(seconds: min(0.1, length.seconds / 2), preferredTimescale: 600)
            track.scaleTimeRange(CMTimeRange(start: length - tail, duration: tail), toDuration: tail + (total - length))
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = SceneCompositor.self
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        videoComposition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        videoComposition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        videoComposition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        videoComposition.instructions = [
            SceneInstruction(timeRange: CMTimeRange(start: .zero, duration: composition.duration),
                             slotTracks: slotTracks, slotOrientations: orientations, box: box, tagging: tagging),
        ]

        return BuiltComposition(asset: composition, videoComposition: videoComposition, duration: composition.duration.seconds)
    }

    /// Speeds pieces of a clip up or down. Works from the end backwards so earlier positions don't move.
    private static func apply(_ map: TimeMap?, to track: AVMutableCompositionTrack, startingAt start: CMTime) {
        guard let map, !map.isIdentity else { return }
        for piece in map.pieces.reversed() where piece.length > 0.001 && abs(piece.rate - 1) > 0.001 {
            let range = CMTimeRange(start: start + CMTime(seconds: piece.start, preferredTimescale: 6000),
                                    duration: CMTime(seconds: piece.length, preferredTimescale: 6000))
            track.scaleTimeRange(range, toDuration: CMTime(seconds: piece.output, preferredTimescale: 6000))
        }
    }

    private static func end(of track: AVMutableCompositionTrack) -> CMTime {
        track.segments.last.map { $0.timeMapping.target.end } ?? .zero
    }
}

/// A one-second, 64×64 black clip used as the clock for screenshot-only videos.
enum TimerClip {
    private static let lock = NSLock()

    static func url() async throws -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("AppX Motion", isDirectory: true)
        try? FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        let url = caches.appendingPathComponent("timer-v1.mp4")
        if FileManager.default.fileExists(atPath: url.path) { return url }

        let tmp = caches.appendingPathComponent("timer-\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: tmp, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &buffer)
        if let buffer {
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) { memset(base, 0, CVPixelBufferGetDataSize(buffer)) }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            for frame in 0..<30 {
                while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
                adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? MediaError.unsupported("timer clip") }
        lock.lock(); defer { lock.unlock() }
        if !FileManager.default.fileExists(atPath: url.path) { try FileManager.default.moveItem(at: tmp, to: url) }
        return url
    }
}
