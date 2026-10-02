import Foundation

/// One-time move from the app's earlier names (PostFrame, Vitrine): settings, templates,
/// captures, exports and saved projects carry over automatically.
enum Migration {
    static let oldFolderNames = ["Vitrine", "PostFrame"]
    static let newFolderName = "AppX Motion"

    static func run() {
        let fm = FileManager.default
        let home = URL(fileURLWithPath: NSHomeDirectory())

        // Folders: ~/Movies/<old> → ~/Movies/AppX Motion, Application Support likewise.
        for base in ["Movies", "Library/Application Support"] {
            let target = home.appendingPathComponent(base).appendingPathComponent(newFolderName)
            for old in oldFolderNames {
                let source = home.appendingPathComponent(base).appendingPathComponent(old)
                if fm.fileExists(atPath: source.path) && !fm.fileExists(atPath: target.path) {
                    try? fm.moveItem(at: source, to: target)
                }
            }
        }

        // Saved projects and sessions: new extension, and media paths that point into a moved folder.
        let folders = [
            home.appendingPathComponent("Library/Application Support/\(newFolderName)/Sessions"),
            home.appendingPathComponent("Movies/\(newFolderName)/Projects"),
        ]
        for folder in folders {
            guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { continue }
            for file in files where ProjectFile.legacyExtensions.contains(file.pathExtension) {
                let target = file.deletingPathExtension().appendingPathExtension(ProjectFile.fileExtension)
                guard !fm.fileExists(atPath: target.path), var text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                for old in oldFolderNames { text = text.replacingOccurrences(of: "/Movies/\(old)/", with: "/Movies/\(newFolderName)/") }
                if (try? text.write(to: target, atomically: true, encoding: .utf8)) != nil { try? fm.removeItem(at: file) }
            }
        }

        // Settings live under the app's bundle ID, which changed with the name.
        // Earlier builds used IDs ending in ".postframe" or ".vitrine"; copy their settings once.
        let defaults = UserDefaults.standard
        guard Bundle.main.bundleIdentifier != nil, defaults.object(forKey: "PostFrame.migrated.v2") == nil else { return }
        let prefs = home.appendingPathComponent("Library/Preferences")
        let oldDomains = ((try? fm.contentsOfDirectory(atPath: prefs.path)) ?? [])
            .filter { $0.hasSuffix(".vitrine.plist") || $0.hasSuffix(".postframe.plist") }
            .map { String($0.dropLast(".plist".count)) }
            .sorted { a, b in a.hasSuffix(".vitrine") && !b.hasSuffix(".vitrine") } // newest name first
        for domain in oldDomains {
            guard let old = defaults.persistentDomain(forName: domain) else { continue }
            for (key, value) in old where key.hasPrefix("PostFrame.") && defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }
        defaults.set(true, forKey: "PostFrame.migrated.v2")
    }
}
