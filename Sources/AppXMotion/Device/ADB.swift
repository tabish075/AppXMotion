import Foundation

enum CaptureError: LocalizedError {
    case adbMissing
    case scrcpyMissing
    case noDevice
    case unauthorized
    case command(String)
    case recordingFailed(String)
    case nothingOnPhone

    var errorDescription: String? {
        switch self {
        case .adbMissing: "adb isn't installed. Install Android platform-tools (brew install android-platform-tools)."
        case .scrcpyMissing: "scrcpy isn't installed. Run: brew install scrcpy"
        case .noDevice: "No phone connected. Plug it in over USB and turn on USB debugging."
        case .unauthorized: "Tap “Allow USB debugging” on your phone, then try again."
        case .command(let message): message.isEmpty ? "The phone didn't respond." : message
        case .recordingFailed(let log): "Recording failed. \(log)"
        case .nothingOnPhone: "No screen recordings or screenshots found on the phone."
        }
    }
}

struct AndroidDevice: Identifiable, Hashable {
    let serial: String
    let state: String
    let model: String

    var id: String { serial }
    var isReady: Bool { state == "device" }
    var isWireless: Bool { serial.contains(":") || serial.contains("._adb-tls") }
    var displayName: String { model.isEmpty ? serial : model }

    /// Parses `adb devices -l`.
    static func parse(_ output: String) -> [AndroidDevice] {
        output.split(separator: "\n").dropFirst().compactMap { line in
            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 2 else { return nil }
            let model = parts.first { $0.hasPrefix("model:") }.map { String($0.dropFirst(6)).replacingOccurrences(of: "_", with: " ") } ?? ""
            return AndroidDevice(serial: parts[0], state: parts[1], model: model)
        }
    }
}

/// A screen recording or screenshot sitting on the phone.
struct RemoteMedia: Identifiable, Hashable {
    let path: String
    let modified: Date
    let size: Int64

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    var isVideo: Bool { ["mp4", "webm", "mkv", "mov", "3gp"].contains((path as NSString).pathExtension.lowercased()) }
}

/// Thin async wrapper around `adb -s <serial> …`.
struct ADB {
    let path: String
    let serial: String

    @discardableResult
    func run(_ args: [String], timeout: Double = 20, check: Bool = true) async throws -> Shell.Result {
        let result = try await Shell.run(path, ["-s", serial] + args, timeout: timeout)
        if check && result.status != 0 {
            if result.message.contains("unauthorized") { throw CaptureError.unauthorized }
            throw CaptureError.command(result.message)
        }
        return result
    }

    @discardableResult
    func shell(_ command: String, timeout: Double = 20, check: Bool = true) async throws -> String {
        try await run(["shell", command], timeout: timeout, check: check).out
    }

    func screencap() async throws -> Data {
        let data = try await run(["exec-out", "screencap", "-p"], timeout: 25).stdout
        guard data.count > 8, data.starts(with: [0x89, 0x50, 0x4E, 0x47]) else {
            throw CaptureError.command("The phone didn't return a screenshot (is the screen on?).")
        }
        return data
    }

    func pull(_ remote: String, to local: URL) async throws {
        try await run(["pull", remote, local.path], timeout: 600)
    }

    // MARK: Theme

    /// "yes", "no", "auto" or "custom".
    func nightMode() async -> String? {
        guard let out = try? await shell("cmd uimode night", timeout: 8) else { return nil }
        return out.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func setNightMode(_ value: String) async throws {
        try await shell("cmd uimode night \(value)", timeout: 8)
    }

    // MARK: Clean status bar (Android System UI demo mode)

    func setDemoMode(_ on: Bool) async throws {
        let demo = "am broadcast -a com.android.systemui.demo -e command"
        let commands = on ? [
            "settings put global sysui_demo_allowed 1",
            "\(demo) enter",
            "\(demo) clock -e hhmm 0941",
            "\(demo) battery -e level 100 -e plugged false",
            "\(demo) network -e wifi show -e level 4 -e fully true",
            "\(demo) network -e mobile show -e datatype none -e level 4 -e fully true",
            "\(demo) notifications -e visible false",
            "\(demo) status -e bluetooth hide -e volume hide -e alarm hide -e location hide -e sync hide -e mute hide -e speakerphone hide -e managed_profile hide",
        ] : ["\(demo) exit"]
        try await shell(commands.joined(separator: " ; "), timeout: 20)
    }

    // MARK: Finding recordings on the phone

    func recentMedia(limit: Int = 60) async throws -> [RemoteMedia] {
        let folders = [
            "/sdcard/Movies", "/sdcard/DCIM/Screen recordings", "/sdcard/DCIM/Screenshots",
            "/sdcard/Pictures/Screenshots", "/sdcard/Pictures/Screen recordings", "/sdcard/Download",
        ]
        let quoted = folders.map { "'\($0)'" }.joined(separator: " ")
        let types = ["mp4", "webm", "mkv", "mov", "png", "jpg", "jpeg"].map { "-iname '*.\($0)'" }.joined(separator: " -o ")
        let command = "find \(quoted) -maxdepth 2 -type f \\( \(types) \\) -exec stat -c '%Y|%s|%n' {} + 2>/dev/null"
        let out = try await shell(command, timeout: 30, check: false)

        var seen = Set<String>()
        let items: [RemoteMedia] = out.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "|", maxSplits: 2).map(String.init)
            guard parts.count == 3, let time = Double(parts[0]), let size = Int64(parts[1]), size > 0 else { return nil }
            guard seen.insert(parts[2]).inserted else { return nil }
            return RemoteMedia(path: parts[2], modified: Date(timeIntervalSince1970: time), size: size)
        }
        return Array(items.sorted { $0.modified > $1.modified }.prefix(limit))
    }
}
