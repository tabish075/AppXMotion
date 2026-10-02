import Foundation

/// Everything needed to reopen a post exactly as you left it.
/// Saved automatically (one session per platform) and on demand as a `.postframe` file.
struct ProjectFile: Codable {
    struct Media: Codable {
        var path: String
        var cropTop: Double
    }

    var version = 1
    var platform: Platform
    var layout: LayoutMode
    var style: StyleSettings
    var media: [Media?]
    var offsets: [Double]
    /// Zooms you placed or adjusted yourself (automatic ones are recalculated on open).
    var zooms: [ZoomSegment]
    var trimIn: Double?
    var trimOut: Double?
    var templateName: String?
    var savedAt = Date()

    static let fileExtension = "appxmotion"
    /// Extensions used by earlier versions of the app.
    static let legacyExtensions = ["vitrine", "postframe"]

    static var sessionsFolder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AppX Motion/Sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static var projectsFolder: URL {
        let folder = Paths.root.appendingPathComponent("Projects", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// The autosaved session for a platform.
    static func sessionURL(_ platform: Platform) -> URL {
        sessionsFolder.appendingPathComponent("\(platform.rawValue).\(fileExtension)")
    }

    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    static func read(from url: URL) throws -> ProjectFile {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ProjectFile.self, from: Data(contentsOf: url))
    }
}
