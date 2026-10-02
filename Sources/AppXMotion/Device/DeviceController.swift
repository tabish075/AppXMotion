import Foundation
import Observation

struct CaptureOptions: Codable, Hashable {
    /// Show the scrcpy mirror window while recording (you can drive the phone with mouse and keyboard).
    var showMirror = true
    /// Android's "show taps" dots, so viewers can follow along.
    var showTouches = true
    var recordAudio = false
    var maxFps = 60
    /// Instant mode: when a recording stops, auto-zoom it and export it straight away.
    var autoExport = true
    /// Put the finished file on the clipboard, ready to paste into X.
    var copyAfterExport = true

    private static let key = "PostFrame.capture.v2"

    static func load() -> CaptureOptions {
        guard let data = UserDefaults.standard.data(forKey: key),
              let value = try? JSONDecoder().decode(CaptureOptions.self, from: data) else { return CaptureOptions() }
        return value
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

/// A running `scrcpy --record` process.
final class ScrcpySession: @unchecked Sendable {
    let output: URL
    private let process = Process()
    private let lock = NSLock()
    private var log = ""
    var onExit: (@Sendable (Int32) -> Void)?

    init(scrcpy: String, adb: String, serial: String, output: URL, options: CaptureOptions) throws {
        self.output = output
        var args = [
            "--serial=\(serial)",
            "--record=\(output.path)",
            "--video-codec=h264",
            "--video-bit-rate=20M",
            "--max-fps=\(options.maxFps)",
            "--stay-awake",
            "--window-title=AppX Motion · Recording (stop it in AppX Motion)",
        ]
        if options.showTouches { args.append("--show-touches") }
        if !options.recordAudio { args.append("--no-audio") }
        if !options.showMirror { args.append("--no-window") }
        process.executableURL = URL(fileURLWithPath: scrcpy)
        process.arguments = args

        var env = ProcessInfo.processInfo.environment
        env["ADB"] = adb
        let adbDir = URL(fileURLWithPath: adb).deletingLastPathComponent().path
        env["PATH"] = [adbDir, "/opt/homebrew/bin", "/usr/local/bin", env["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            self?.append(text)
        }
        process.terminationHandler = { [weak self] proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            self?.onExit?(proc.terminationStatus)
        }
        try process.run()
    }

    private func append(_ text: String) {
        lock.lock()
        log += text
        if log.count > 20_000 { log = String(log.suffix(10_000)) }
        lock.unlock()
    }

    /// The last few meaningful lines of scrcpy's output, for error messages.
    var tail: String {
        lock.lock(); defer { lock.unlock() }
        let lines = log.split(separator: "\n").filter { $0.contains("ERROR") || $0.contains("WARN") || $0.contains("error") }
        return lines.suffix(3).joined(separator: " ")
    }

    var isRunning: Bool { process.isRunning }

    var fullLog: String {
        lock.lock(); defer { lock.unlock() }
        return log
    }

    /// Ctrl-C lets scrcpy finalise the MP4; force-quit only if it hangs.
    func stop() {
        guard process.isRunning else { return }
        process.interrupt()
        DispatchQueue.global().asyncAfter(deadline: .now() + 8) { [process] in
            if process.isRunning { process.terminate() }
        }
    }
}

@Observable @MainActor
final class DeviceController {
    private(set) var devices: [AndroidDevice] = []
    var selectedSerial: String?
    let adbPath = ToolLocator.adb
    let scrcpyPath = ToolLocator.scrcpy
    /// Shown while a multi-step capture is running.
    var busyMessage: String?
    private(set) var recordingStartedAt: Date?
    var cleanStatusBar = false
    var options = CaptureOptions.load() { didSet { options.save() } }

    private var session: ScrcpySession?
    private var monitor: Task<Void, Never>?

    var isRecording: Bool { session != nil }
    var device: AndroidDevice? {
        devices.first { $0.serial == selectedSerial && $0.isReady } ?? devices.first { $0.isReady }
    }
    var unauthorizedDevice: AndroidDevice? { devices.first { $0.state == "unauthorized" } }

    func startMonitoring() {
        guard monitor == nil, adbPath != nil else { return }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshDevices()
                try? await Task.sleep(for: .seconds(2.5))
            }
        }
    }

    func refreshDevices() async {
        guard let adbPath, let result = try? await Shell.run(adbPath, ["devices", "-l"], timeout: 6) else { return }
        let parsed = AndroidDevice.parse(result.out)
        if parsed != devices { devices = parsed }
        if selectedSerial == nil || !devices.contains(where: { $0.serial == selectedSerial }) {
            selectedSerial = devices.first(where: \.isReady)?.serial
        }
    }

    private func adb() throws -> ADB {
        guard let adbPath else { throw CaptureError.adbMissing }
        guard let device else { throw unauthorizedDevice != nil ? CaptureError.unauthorized : CaptureError.noDevice }
        return ADB(path: adbPath, serial: device.serial)
    }

    // MARK: Screenshots

    func screenshot() async throws -> URL {
        let adb = try adb()
        busyMessage = "Capturing screenshot…"
        defer { busyMessage = nil }
        let data = try await adb.screencap()
        let url = Paths.unique(Paths.captures.appendingPathComponent("Screenshot \(Paths.timestamp()).png"))
        try data.write(to: url)
        return url
    }

    /// Captures the current screen in light mode, then in dark mode, then restores the phone's theme.
    func lightDarkScreenshots() async throws -> (light: URL, dark: URL) {
        let adb = try adb()
        defer { busyMessage = nil }
        let original = await adb.nightMode()
        busyMessage = "Switching phone to light mode…"
        try await adb.setNightMode("no")
        try await Task.sleep(for: .seconds(1.8))
        busyMessage = "Capturing light…"
        let light = try await adb.screencap()
        busyMessage = "Switching phone to dark mode…"
        try await adb.setNightMode("yes")
        try await Task.sleep(for: .seconds(2.0))
        busyMessage = "Capturing dark…"
        let dark = try await adb.screencap()
        if let original, original != "yes" { try? await adb.setNightMode(original) }

        let stamp = Paths.timestamp()
        let lightURL = Paths.unique(Paths.captures.appendingPathComponent("Light \(stamp).png"))
        let darkURL = Paths.unique(Paths.captures.appendingPathComponent("Dark \(stamp).png"))
        try light.write(to: lightURL)
        try dark.write(to: darkURL)
        return (lightURL, darkURL)
    }

    // MARK: Theme & status bar

    func isDarkMode() async -> Bool? {
        guard let adb = try? adb(), let mode = await adb.nightMode() else { return nil }
        return mode == "yes"
    }

    /// Returns the previous mode so it can be restored.
    @discardableResult
    func setDarkMode(_ dark: Bool) async throws -> String? {
        let adb = try adb()
        let previous = await adb.nightMode()
        try await adb.setNightMode(dark ? "yes" : "no")
        return previous
    }

    func restoreNightMode(_ mode: String?) async {
        guard let mode, let adb = try? adb() else { return }
        try? await adb.setNightMode(mode)
    }

    func setCleanStatusBar(_ on: Bool) async throws {
        try await adb().setDemoMode(on)
        cleanStatusBar = on
    }

    // MARK: Recording

    func startRecording(onFinish: @escaping @MainActor (Result<URL, Error>) -> Void) throws {
        guard session == nil else { return }
        guard let scrcpyPath else { throw CaptureError.scrcpyMissing }
        let adb = try adb()
        let url = Paths.unique(Paths.captures.appendingPathComponent("Recording \(Paths.timestamp()).mp4"))
        let session = try ScrcpySession(scrcpy: scrcpyPath, adb: adb.path, serial: adb.serial, output: url, options: options)
        session.onExit = { [weak self, weak session] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.session = nil
                    self.recordingStartedAt = nil
                    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
                    if size > 4096 {
                        onFinish(.success(url))
                    } else {
                        onFinish(.failure(CaptureError.recordingFailed(session?.tail ?? "")))
                    }
                }
            }
        }
        self.session = session
        recordingStartedAt = Date()
    }

    func stopRecording() {
        session?.stop()
    }

    // MARK: Phone gallery

    func recentMedia() async throws -> [RemoteMedia] {
        try await adb().recentMedia()
    }

    func pull(_ media: RemoteMedia) async throws -> URL {
        let adb = try adb()
        busyMessage = "Copying \(media.name) from phone…"
        defer { busyMessage = nil }
        let url = Paths.unique(Paths.captures.appendingPathComponent(media.name))
        try await adb.pull(media.path, to: url)
        return url
    }

    /// Called when the app quits so scrcpy can finish writing.
    func shutdown() {
        session?.stop()
        monitor?.cancel()
    }
}
