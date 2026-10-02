import AppKit
import AVFoundation
import CoreImage
import UniformTypeIdentifiers

enum MediaError: LocalizedError {
    case unsupported(String)
    case unreadableImage(String)
    case noVideoTrack(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let name): "“\(name)” isn't a video or image AppX Motion can open."
        case .unreadableImage(let name): "Couldn't read the image “\(name)”."
        case .noVideoTrack(let name): "“\(name)” has no video track."
        }
    }
}

/// A click recorded while capturing a Mac window (clip time, position 0…1 across/down the window).
struct ClickPoint: Codable, Hashable {
    var t: Double
    var u: Double
    var v: Double
}

/// A screen recording or screenshot loaded into one of the phone slots.
struct MediaItem: Identifiable {
    enum Kind { case video, image }

    let id = UUID()
    let url: URL
    let kind: Kind
    /// Display size after applying any rotation metadata.
    let pixelSize: CGSize
    let duration: Double
    let orientation: CGImagePropertyOrientation
    let hasAudio: Bool
    /// Decoded image for screenshots.
    let still: CIImage?
    let thumbnail: NSImage?
    /// Fraction of the height trimmed off the top (e.g. a browser's own toolbar).
    var cropTop: CGFloat = 0
    /// Clicks captured while recording a Mac window.
    var clicks: [ClickPoint] = []
    /// Bundle ID of the app that was recorded (web captures).
    var sourceApp: String?

    var name: String { url.lastPathComponent }
    var aspect: CGFloat {
        let h = pixelSize.height * (1 - cropTop)
        return h > 0 ? pixelSize.width / h : 9.0 / 20.0
    }
    var isVideo: Bool { kind == .video }

    var summary: String {
        let dims = "\(Int(pixelSize.width))×\(Int(pixelSize.height))"
        guard isVideo else { return "Screenshot · \(dims)" }
        return "\(Self.formatDuration(duration)) · \(dims)"
    }

    static func formatDuration(_ seconds: Double) -> String {
        let s = max(0, seconds)
        return String(format: "%d:%04.1f", Int(s) / 60, s.truncatingRemainder(dividingBy: 60))
    }

    // MARK: Loading

    /// Sidecar file written next to Mac window recordings.
    struct CaptureInfo: Codable {
        var app: String?
        var cropTop: Double?
        var clicks: [ClickPoint]
    }

    static func sidecarURL(for url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension("appxmotion.json")
    }

    /// Sidecars written by earlier versions of the app.
    static func legacySidecarURLs(for url: URL) -> [URL] {
        ["vitrine.json", "postframe.json"].map { url.deletingPathExtension().appendingPathExtension($0) }
    }

    static func load(_ url: URL) async throws -> MediaItem {
        var item = try await loadMedia(url)
        if let data = ([sidecarURL(for: url)] + legacySidecarURLs(for: url)).lazy.compactMap({ try? Data(contentsOf: $0) }).first,
           let info = try? JSONDecoder().decode(CaptureInfo.self, from: data) {
            item.clicks = info.clicks
            item.sourceApp = info.app
            item.cropTop = CGFloat(info.cropTop ?? 0)
        }
        return item
    }

    private static func loadMedia(_ url: URL) async throws -> MediaItem {
        let type = UTType(filenameExtension: url.pathExtension.lowercased())
        if let type, type.conforms(to: .image) {
            return try loadImage(url)
        }
        do {
            return try await loadVideo(url)
        } catch {
            // Formats AVFoundation can't read (webm, mkv…) are converted with ffmpeg when it's installed.
            guard let ffmpeg = ToolLocator.ffmpeg, !url.lastPathComponent.contains("(converted)") else { throw error }
            let converted = try await transcode(url, ffmpeg: ffmpeg)
            return try await loadVideo(converted)
        }
    }

    private static func loadImage(_ url: URL) throws -> MediaItem {
        guard var image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
            throw MediaError.unreadableImage(url.lastPathComponent)
        }
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        return MediaItem(url: url, kind: .image, pixelSize: image.extent.size, duration: 0, orientation: .up,
                         hasAudio: false, still: image, thumbnail: NSImage(contentsOf: url))
    }

    private static func loadVideo(_ url: URL) async throws -> MediaItem {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw MediaError.noVideoTrack(url.lastPathComponent)
        }
        let (natural, transform, range) = try await track.load(.naturalSize, .preferredTransform, .timeRange)
        let rotated = natural.applying(transform)
        let size = CGSize(width: abs(rotated.width), height: abs(rotated.height))
        let hasAudio = !(try await asset.loadTracks(withMediaType: .audio)).isEmpty
        let duration = range.duration.seconds

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 400, height: 400)
        var thumbnail: NSImage?
        if let (cg, _) = try? await generator.image(at: CMTime(seconds: min(0.5, duration / 2), preferredTimescale: 600)) {
            thumbnail = NSImage(cgImage: cg, size: CGSize(width: cg.width, height: cg.height))
        }

        return MediaItem(url: url, kind: .video, pixelSize: size, duration: duration,
                         orientation: orientation(for: transform), hasAudio: hasAudio, still: nil, thumbnail: thumbnail)
    }

    static func orientation(for t: CGAffineTransform) -> CGImagePropertyOrientation {
        if t.a == 0 && t.b == 1 && t.c == -1 && t.d == 0 { return .right }
        if t.a == 0 && t.b == -1 && t.c == 1 && t.d == 0 { return .left }
        if t.a == -1 && t.b == 0 && t.c == 0 && t.d == -1 { return .down }
        return .up
    }

    private static func transcode(_ url: URL, ffmpeg: String) async throws -> URL {
        let out = Paths.unique(Paths.captures.appendingPathComponent(url.deletingPathExtension().lastPathComponent + " (converted).mp4"))
        let result = try await Shell.run(ffmpeg, [
            "-y", "-i", url.path,
            "-c:v", "libx264", "-preset", "veryfast", "-crf", "14", "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-b:a", "160k",
            out.path,
        ], timeout: 600)
        guard result.status == 0, FileManager.default.fileExists(atPath: out.path) else {
            throw MediaError.unsupported(url.lastPathComponent)
        }
        return out
    }
}
