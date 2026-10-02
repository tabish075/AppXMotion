import AppKit
import Observation
import ScreenCaptureKit

/// A window that can be recorded.
struct CapturableWindow: Identifiable, Hashable {
    let id: CGWindowID
    let title: String
    let appName: String
    let bundleID: String
    let frame: CGRect

    var isBrowser: Bool { BrowserBar.knownBrowsers.contains(bundleID) }
    var label: String { title.isEmpty ? appName : "\(appName) — \(title)" }
}

struct MacCaptureOptions: Codable, Hashable {
    var showCursor = true
    /// Trim the browser's own tabs/address bar off recordings (handy with the drawn Browser frame).
    var hideBrowserBar = false

    private static let key = "PostFrame.macCapture.v1"
    static func load() -> MacCaptureOptions {
        guard let data = UserDefaults.standard.data(forKey: key), let value = try? JSONDecoder().decode(MacCaptureOptions.self, from: data) else { return MacCaptureOptions() }
        return value
    }
    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

enum MacCaptureError: LocalizedError {
    case permission
    case noWindow
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .permission: "AppX Motion needs Screen Recording permission. Turn it on in System Settings › Privacy & Security › Screen & System Audio Recording, then try again."
        case .noWindow: "Pick a window to capture first (e.g. your browser)."
        case .failed(let message): message
        }
    }
}

/// Records or screenshots a single Mac window (works even if it's partly covered), and logs your clicks.
@Observable @MainActor
final class MacCapture {
    private(set) var windows: [CapturableWindow] = []
    var selectedWindowID: CGWindowID?
    private(set) var recordingStartedAt: Date?
    var busyMessage: String?
    var options = MacCaptureOptions.load() { didSet { options.save() } }
    @ObservationIgnored private var scWindows: [CGWindowID: SCWindow] = [:]
    @ObservationIgnored private var recording: WindowRecording?

    var isRecording: Bool { recording != nil }
    var selectedWindow: CapturableWindow? { windows.first { $0.id == selectedWindowID } }

    func refreshWindows() async throws {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        } catch {
            throw MacCaptureError.permission
        }
        let ownBundle = Bundle.main.bundleIdentifier ?? "com.evolvosofts.appxmotion"
        var map: [CGWindowID: SCWindow] = [:]
        let list: [CapturableWindow] = content.windows.compactMap { window in
            guard window.windowLayer == 0, window.frame.width >= 320, window.frame.height >= 240,
                  let app = window.owningApplication, !app.bundleIdentifier.hasPrefix(ownBundle),
                  !["com.apple.dock", "com.apple.WindowManager", "com.apple.controlcenter"].contains(app.bundleIdentifier) else { return nil }
            map[window.windowID] = window
            return CapturableWindow(id: window.windowID, title: window.title ?? "", appName: app.applicationName,
                                    bundleID: app.bundleIdentifier, frame: window.frame)
        }
        scWindows = map
        // Browsers first, then everything else.
        windows = list.sorted { ($0.isBrowser ? 0 : 1, $0.appName) < ($1.isBrowser ? 0 : 1, $1.appName) }
        if selectedWindowID == nil || !windows.contains(where: { $0.id == selectedWindowID }) {
            selectedWindowID = windows.first?.id
        }
    }

    private func target() throws -> (SCWindow, CapturableWindow) {
        guard let info = selectedWindow, let window = scWindows[info.id] else { throw MacCaptureError.noWindow }
        return (window, info)
    }

    // MARK: Screenshot

    func screenshot() async throws -> URL {
        try await refreshWindows()
        let (window, info) = try target()
        busyMessage = "Capturing \(info.appName)…"
        defer { busyMessage = nil }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.width = Int(filter.contentRect.width * scale)
        config.height = Int(filter.contentRect.height * scale)
        config.showsCursor = false
        config.colorSpaceName = CGColorSpace.sRGB
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let url = Paths.unique(Paths.captures.appendingPathComponent("\(info.appName) \(Paths.timestamp()).png"))
        try RenderCore.writeImage(image, to: url, format: .png)
        let crop = options.hideBrowserBar && info.isBrowser ? BrowserBar.detect(in: image, bundleID: info.bundleID) : nil
        try? JSONEncoder().encode(MediaItem.CaptureInfo(app: info.bundleID, cropTop: crop.map(Double.init), clicks: []))
            .write(to: MediaItem.sidecarURL(for: url))
        return url
    }

    // MARK: Recording

    func startRecording(onFinish: @escaping @MainActor (Result<URL, Error>) -> Void) async throws {
        guard recording == nil else { return }
        try await refreshWindows()
        let (window, info) = try target()
        let url = Paths.unique(Paths.captures.appendingPathComponent("\(info.appName) \(Paths.timestamp()).mp4"))
        let session = try WindowRecording(window: window, info: info, url: url, showCursor: options.showCursor, hideBrowserBar: options.hideBrowserBar)
        session.onFinish = { [weak self] result in
            Task { @MainActor in
                self?.recording = nil
                self?.recordingStartedAt = nil
                onFinish(result)
            }
        }
        try await session.start()
        recording = session
        recordingStartedAt = Date()
    }

    func stopRecording() {
        guard let recording else { return }
        Task { await recording.stop() }
    }
}

/// One window recording: ScreenCaptureKit writes the MP4; a global mouse monitor logs clicks.
final class WindowRecording: NSObject, SCRecordingOutputDelegate, SCStreamOutput, @unchecked Sendable {
    private let stream: SCStream
    private var output: SCRecordingOutput?
    private let url: URL
    private let info: CapturableWindow
    private let hideBrowserBar: Bool
    private var startedAt: CFTimeInterval?
    private var clicks: [ClickPoint] = []
    private var clickMonitor: Any?
    private let lock = NSLock()
    private let sampleQueue = DispatchQueue(label: "PostFrame.capture.samples")
    private var firstFrame: CGImage?
    var onFinish: ((Result<URL, Error>) -> Void)?

    init(window: SCWindow, info: CapturableWindow, url: URL, showCursor: Bool, hideBrowserBar: Bool) throws {
        self.url = url
        self.info = info
        self.hideBrowserBar = hideBrowserBar
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.width = Int(filter.contentRect.width * scale) / 2 * 2
        config.height = Int(filter.contentRect.height * scale) / 2 * 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.showsCursor = showCursor
        config.queueDepth = 6
        config.colorSpaceName = CGColorSpace.sRGB
        config.capturesAudio = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        stream = SCStream(filter: filter, configuration: config, delegate: nil)
        super.init()
        let recordingConfig = SCRecordingOutputConfiguration()
        recordingConfig.outputURL = url
        recordingConfig.outputFileType = .mp4
        recordingConfig.videoCodecType = .h264
        output = SCRecordingOutput(configuration: recordingConfig, delegate: self)
    }

    func start() async throws {
        guard let output else { throw MacCaptureError.failed("Couldn't set up the recording.") }
        do {
            try stream.addRecordingOutput(output)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
            try await stream.startCapture()
        } catch {
            throw MacCaptureError.failed("Couldn't start recording: \(error.localizedDescription)")
        }
        await MainActor.run {
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
                self?.recordClick()
            }
        }
    }

    func stop() async {
        await MainActor.run {
            if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
            clickMonitor = nil
        }
        do {
            try await stream.stopCapture()
        } catch {
            onFinish?(.failure(MacCaptureError.failed("Couldn't stop recording: \(error.localizedDescription)")))
        }
    }

    /// Converts the click to a position inside the window (0…1), using the window's current frame.
    private func recordClick() {
        lock.lock()
        let started = startedAt
        lock.unlock()
        guard let started else { return }
        let time = CACurrentMediaTime() - started
        let mouse = NSEvent.mouseLocation
        guard let primary = NSScreen.screens.first else { return }
        let point = CGPoint(x: mouse.x, y: primary.frame.height - mouse.y)
        var frame = info.frame
        if let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], info.id) as? [[String: Any]],
           let bounds = list.first?[kCGWindowBounds as String] as? [String: CGFloat] {
            frame = CGRect(x: bounds["X"] ?? frame.minX, y: bounds["Y"] ?? frame.minY, width: bounds["Width"] ?? frame.width, height: bounds["Height"] ?? frame.height)
        }
        let u = (point.x - frame.minX) / frame.width, v = (point.y - frame.minY) / frame.height
        guard (0...1).contains(u), (0...1).contains(v) else { return }
        lock.lock()
        clicks.append(ClickPoint(t: time, u: Double(u), v: Double(v)))
        lock.unlock()
    }

    // MARK: SCStreamOutput (keeps the first frame for browser-bar detection)

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard hideBrowserBar, firstFrame == nil, type == .screen, let buffer = sampleBuffer.imageBuffer else { return }
        let image = CIImage(cvPixelBuffer: buffer)
        firstFrame = RenderCore.context.createCGImage(image, from: image.extent)
    }

    // MARK: SCRecordingOutputDelegate

    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        lock.lock()
        startedAt = CACurrentMediaTime()
        lock.unlock()
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        onFinish?(.failure(MacCaptureError.failed("Recording failed: \(error.localizedDescription)")))
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        lock.lock()
        let clicks = self.clicks
        lock.unlock()
        let crop = hideBrowserBar && info.isBrowser ? firstFrame.flatMap { BrowserBar.detect(in: $0, bundleID: info.bundleID) } : nil
        let sidecar = MediaItem.CaptureInfo(app: info.bundleID, cropTop: crop.map(Double.init), clicks: clicks)
        try? JSONEncoder().encode(sidecar).write(to: MediaItem.sidecarURL(for: url))
        onFinish?(.success(url))
    }
}

/// Finds where a browser's own toolbar ends, so it can be trimmed off.
enum BrowserBar {
    static let knownBrowsers: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.canary", "com.apple.Safari", "com.apple.SafariTechnologyPreview",
        "org.mozilla.firefox", "com.microsoft.edgemac", "com.brave.Browser", "company.thebrowser.Browser",
        "com.operasoftware.Opera", "com.vivaldi.Vivaldi", "app.zen-browser.zen",
    ]

    /// Typical toolbar heights in points (tabs + address bar), used to pick the right edge.
    private static func expectedHeight(_ bundleID: String) -> CGFloat? {
        switch bundleID {
        case "com.google.Chrome", "com.google.Chrome.canary", "com.brave.Browser", "com.microsoft.edgemac", "com.vivaldi.Vivaldi": 87
        case "com.apple.Safari", "com.apple.SafariTechnologyPreview": 52
        case "org.mozilla.firefox", "app.zen-browser.zen": 80
        case "com.operasoftware.Opera": 84
        default: nil
        }
    }

    /// Returns the fraction of the height to trim, or nil if no clear toolbar edge is found.
    static func detect(in image: CGImage, bundleID: String? = nil) -> CGFloat? {
        let w = 360, h = Int(Double(image.height) / Double(image.width) * 360)
        guard h > 40, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        // Row 0 of the bitmap memory is the top of the image.
        func px(_ x: Int, _ y: Int) -> Int { Int(data[y * w + x]) }
        let maxRow = Int(Double(h) * 0.22)
        var candidates: [(row: Int, strength: Double)] = []
        for y in 2..<maxRow {
            var spanning = 0
            var total = 0
            for x in 0..<w {
                let d = abs(px(x, y) - px(x, y + 1))
                total += d
                if d > 5 { spanning += 1 }
            }
            if Double(spanning) > Double(w) * 0.85 { candidates.append((y + 1, Double(total) / Double(w))) }
        }
        guard !candidates.isEmpty else { return nil }
        let pointsPerRow = Double(image.height) / Double(h) / 2 // retina: 2 px per point
        if let bundleID, let expected = expectedHeight(bundleID) {
            let best = candidates.min { abs(Double($0.row) * pointsPerRow - expected) < abs(Double($1.row) * pointsPerRow - expected) }!
            if abs(Double(best.row) * pointsPerRow - expected) < 40 { return CGFloat(best.row) / CGFloat(h) }
        }
        let strongest = candidates.max { $0.strength < $1.strength }!
        return CGFloat(strongest.row) / CGFloat(h)
    }
}
