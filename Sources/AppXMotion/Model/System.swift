import Foundation

// MARK: - Folders

enum Paths {
    static let root: URL = {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Movies")
        return movies.appendingPathComponent("AppX Motion", isDirectory: true)
    }()

    /// Raw captures from the phone (kept so nothing is ever lost).
    static var captures: URL { ensure(root.appendingPathComponent("Captures", isDirectory: true)) }
    /// Finished, X-ready files.
    static var exports: URL { ensure(root.appendingPathComponent("Exports", isDirectory: true)) }

    static func timestamp(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f.string(from: date)
    }

    /// Returns `url`, or `url` with " 2", " 3"… appended if a file already exists there.
    static func unique(_ url: URL) -> URL {
        var candidate = url
        var n = 2
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = url.deletingLastPathComponent().appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return candidate
    }

    @discardableResult
    private static func ensure(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

// MARK: - External tools

/// GUI apps don't inherit the shell PATH, so look for the command-line tools in the usual places.
enum ToolLocator {
    static let adb: String? = find("adb", preferred: adbCandidates)
    static let scrcpy: String? = find("scrcpy")
    static let ffmpeg: String? = find("ffmpeg")

    private static var adbCandidates: [String] {
        let env = ProcessInfo.processInfo.environment
        var list = ["\(NSHomeDirectory())/Library/Android/sdk/platform-tools/adb"]
        for key in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
            if let root = env[key] { list.append("\(root)/platform-tools/adb") }
        }
        return list
    }

    static func find(_ name: String, preferred: [String] = []) -> String? {
        let candidates = preferred + ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)"]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        // Fall back to the user's login shell PATH.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v \(name)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return FileManager.default.isExecutableFile(atPath: out) ? out : nil
    }
}

// MARK: - Running processes

enum Shell {
    struct Result {
        let status: Int32
        let stdout: Data
        let stderr: String
        var out: String { String(data: stdout, encoding: .utf8) ?? "" }
        var message: String {
            let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? out.trimmingCharacters(in: .whitespacesAndNewlines) : text
        }
    }

    struct TimeoutError: LocalizedError {
        let command: String
        var errorDescription: String? { "\(command) did not respond in time." }
    }

    /// Runs a process to completion off the main thread, draining both pipes concurrently.
    static func run(_ executable: String, _ arguments: [String], environment: [String: String]? = nil, timeout: Double? = nil) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                if let environment {
                    process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
                }
                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe
                process.standardInput = FileHandle.nullDevice

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                var timedOut = false
                var timer: DispatchWorkItem?
                if let timeout {
                    let item = DispatchWorkItem {
                        if process.isRunning {
                            timedOut = true
                            process.terminate()
                        }
                    }
                    timer = item
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: item)
                }

                var errData = Data()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()
                timer?.cancel()

                if timedOut {
                    let name = URL(fileURLWithPath: executable).lastPathComponent
                    continuation.resume(throwing: TimeoutError(command: ([name] + arguments.prefix(3)).joined(separator: " ")))
                    return
                }
                continuation.resume(returning: Result(
                    status: process.terminationStatus,
                    stdout: outData,
                    stderr: String(data: errData, encoding: .utf8) ?? ""
                ))
            }
        }
    }
}
