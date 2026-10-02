import AppKit
import CoreGraphics

// MARK: - Color

/// An sRGB colour that can be persisted.
struct RGBAColor: Codable, Hashable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double

    init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    init(hex: UInt32, alpha: Double = 1) {
        self.init(Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255, alpha)
    }

    init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? .black
        self.init(Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent), Double(c.alphaComponent))
    }

    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }

    /// WCAG relative luminance.
    var luminance: Double {
        func lin(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    func mixed(with o: RGBAColor, _ t: Double) -> RGBAColor {
        RGBAColor(r + (o.r - r) * t, g + (o.g - g) * t, b + (o.b - b) * t, a + (o.a - a) * t)
    }

    func alpha(_ value: Double) -> RGBAColor { RGBAColor(r, g, b, value) }

    static let white = RGBAColor(1, 1, 1)
    static let black = RGBAColor(0, 0, 0)
}

// MARK: - Canvas

enum CanvasPreset: String, Codable, CaseIterable, Identifiable {
    case landscape, square, portrait, tall, story

    var id: String { rawValue }

    /// Output size in pixels. All sizes sit inside X's 1920×1200 / 1200×1900 upload limits
    /// (9:16 is slightly taller; X downsizes it without cropping).
    var size: CGSize {
        switch self {
        case .landscape: CGSize(width: 1920, height: 1080)
        case .square: CGSize(width: 1200, height: 1200)
        case .portrait: CGSize(width: 1200, height: 1500)
        case .tall: CGSize(width: 1200, height: 1600)
        case .story: CGSize(width: 1080, height: 1920)
        }
    }

    var ratio: String {
        switch self {
        case .landscape: "16:9"
        case .square: "1:1"
        case .portrait: "4:5"
        case .tall: "3:4"
        case .story: "9:16"
        }
    }

    var hint: String {
        switch self {
        case .landscape: "Wide. Great for 2–3 phones side by side."
        case .square: "Balanced. Works for single phones and comparisons."
        case .portrait: "Tall feed post. Biggest phone in the X timeline."
        case .tall: "Extra tall. Very large single phone."
        case .story: "Full vertical. X shows it smaller in the feed."
        }
    }
}

enum LayoutMode: String, Codable, CaseIterable, Identifiable {
    /// One phone.
    case single
    /// Two phones side by side (light vs dark, before vs after).
    case compare
    /// Several screens on a board; the camera tours them one by one.
    case tour
    var id: String { rawValue }
}

// MARK: - Background

enum BackgroundStyle: String, Codable, CaseIterable, Identifiable {
    case solid, gradient, radial, blurredApp
    var id: String { rawValue }
    var label: String {
        switch self {
        case .solid: "Solid"
        case .gradient: "Gradient"
        case .radial: "Glow"
        case .blurredApp: "App blur"
        }
    }
}

struct BackgroundSettings: Codable, Hashable {
    var style: BackgroundStyle = .gradient
    var color1 = RGBAColor(hex: 0xF7F8FA)
    var color2 = RGBAColor(hex: 0xE4E7EE)
    /// CSS-style angle: 0 = towards top, 90 = towards right, 180 = towards bottom.
    var angle: Double = 180

    static func solid(_ hex: UInt32) -> BackgroundSettings {
        BackgroundSettings(style: .solid, color1: RGBAColor(hex: hex), color2: RGBAColor(hex: hex), angle: 180)
    }
    static func gradient(_ a: UInt32, _ b: UInt32, _ angle: Double = 135) -> BackgroundSettings {
        BackgroundSettings(style: .gradient, color1: RGBAColor(hex: a), color2: RGBAColor(hex: b), angle: angle)
    }
    static func radial(_ center: UInt32, _ edge: UInt32) -> BackgroundSettings {
        BackgroundSettings(style: .radial, color1: RGBAColor(hex: center), color2: RGBAColor(hex: edge), angle: 0)
    }

    /// Average colour, used for automatic text contrast.
    var averageColor: RGBAColor {
        style == .blurredApp ? RGBAColor(hex: 0x202020) : color1.mixed(with: color2, 0.5)
    }
}

struct BackgroundPreset: Identifiable {
    let id: String
    let name: String
    let settings: BackgroundSettings

    static let all: [BackgroundPreset] = [
        .init(id: "white", name: "White", settings: .solid(0xFFFFFF)),
        .init(id: "board", name: "Board grey", settings: .solid(0xEDEDEB)),
        .init(id: "mist", name: "Mist", settings: .gradient(0xF7F8FA, 0xE4E7EE, 180)),
        .init(id: "sand", name: "Sand", settings: .gradient(0xFBF6EE, 0xEEE2CF, 160)),
        .init(id: "peach", name: "Peach", settings: .gradient(0xFFECD2, 0xFCB69F)),
        .init(id: "cotton", name: "Cotton Candy", settings: .gradient(0xFBC2EB, 0xA6C1EE)),
        .init(id: "sky", name: "Sky", settings: .gradient(0xA1C4FD, 0xC2E9FB)),
        .init(id: "mint", name: "Mint", settings: .gradient(0xD4FC79, 0x96E6A1)),
        .init(id: "ocean", name: "Ocean", settings: .gradient(0x4FACFE, 0x00F2FE)),
        .init(id: "grape", name: "Grape", settings: .gradient(0x667EEA, 0x764BA2)),
        .init(id: "sunset", name: "Sunset", settings: .gradient(0xFF9A8B, 0xFF6A88)),
        .init(id: "ember", name: "Ember", settings: .gradient(0xF83600, 0xF9D423)),
        .init(id: "lime", name: "Lime", settings: .gradient(0x0BA360, 0x3CBA92)),
        .init(id: "spotlight", name: "Spotlight", settings: .radial(0x30343F, 0x0A0B0E)),
        .init(id: "midnight", name: "Midnight", settings: .gradient(0x141E30, 0x243B55, 160)),
        .init(id: "dim", name: "X Dim", settings: .solid(0x15202B)),
        .init(id: "black", name: "Black", settings: .solid(0x000000)),
        .init(id: "blur", name: "App Blur: the app's own colours, blurred",
              settings: BackgroundSettings(style: .blurredApp, color1: RGBAColor(hex: 0x111111), color2: RGBAColor(hex: 0x111111), angle: 0)),
    ]
}

// MARK: - Device

/// What you're showing off. Each platform has its own workspace, look and templates.
enum Platform: String, Codable, CaseIterable, Identifiable {
    case android, web
    var id: String { rawValue }
    var label: String { self == .android ? "Android app" : "Web app" }
    var icon: String { self == .android ? "iphone.gen3" : "macwindow" }
}

enum FrameStyle: String, Codable, CaseIterable, Identifiable {
    // Android
    /// Realistic 3D Galaxy S26 Ultra (SceneKit).
    case galaxy3D
    case phone, minimal, screenOnly
    // Web
    /// Clean browser window drawn around the page (traffic lights + address bar).
    case browser
    /// The recording as-is with rounded corners (keeps the real browser UI).
    case window
    /// Realistic 3D MacBook (SceneKit).
    case macbook3D

    var id: String { rawValue }
    var label: String {
        switch self {
        case .galaxy3D: "S26 Ultra"
        case .phone: "Flat"
        case .minimal: "Slim"
        case .screenOnly: "Screen"
        case .browser: "Browser"
        case .window: "Window"
        case .macbook3D: "MacBook"
        }
    }
    var is3D: Bool { self == .galaxy3D || self == .macbook3D }
    var platform: Platform { [.browser, .window, .macbook3D].contains(self) ? .web : .android }
    static func styles(for platform: Platform) -> [FrameStyle] { allCases.filter { $0.platform == platform } }
}

enum ChromeTheme: String, Codable, CaseIterable, Identifiable {
    case light, dark
    var id: String { rawValue }
}

struct FrameColor: Identifiable {
    let id: String
    let name: String
    let body: RGBAColor
    let highlight: RGBAColor

    static let all: [FrameColor] = [
        FrameColor(id: "obsidian", name: "Obsidian", body: RGBAColor(hex: 0x1C1C1E), highlight: RGBAColor(hex: 0x5A5A60)),
        FrameColor(id: "graphite", name: "Graphite", body: RGBAColor(hex: 0x3B3C40), highlight: RGBAColor(hex: 0x8A8B90)),
        FrameColor(id: "silver", name: "Silver", body: RGBAColor(hex: 0xD5D6DB), highlight: RGBAColor(hex: 0xFFFFFF)),
        FrameColor(id: "porcelain", name: "Porcelain", body: RGBAColor(hex: 0xEDE6DC), highlight: RGBAColor(hex: 0xFFFFFF)),
        FrameColor(id: "bay", name: "Bay", body: RGBAColor(hex: 0x9FBCE3), highlight: RGBAColor(hex: 0xE3EEFF)),
        FrameColor(id: "sage", name: "Sage", body: RGBAColor(hex: 0xA9BCA0), highlight: RGBAColor(hex: 0xE5EFE0)),
        FrameColor(id: "rose", name: "Rose", body: RGBAColor(hex: 0xE6BFC0), highlight: RGBAColor(hex: 0xFFEDEE)),
    ]

    static func named(_ id: String) -> FrameColor { all.first { $0.id == id } ?? all[0] }
}

struct DeviceSettings: Codable, Hashable {
    var style: FrameStyle = .galaxy3D
    /// Titanium finish for the 3D phone.
    var finishID: String = "ti-black"
    var pose: DevicePose = .front
    /// Frame colour for the flat (2D) frames.
    var frameColorID: String = "obsidian"
    /// Fraction of the available space the device occupies.
    var size: Double = 0.92
    /// Corner roundness multiplier.
    var roundness: Double = 1.0
    var showCamera = true
    var showButtons = true
    // Web
    /// Text shown in the drawn browser's address bar.
    var browserURL = "yourapp.com"
    var chromeTheme: ChromeTheme = .light
    /// MacBook finish.
    var laptopFinishID = "space-black"
    /// Little ripples where you clicked (web recordings made in AppX Motion).
    var showClicks = true
}

extension DeviceSettings {
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func read<T: Decodable>(_ type: T.Type, _ key: CodingKeys) -> T? { (try? c.decodeIfPresent(type, forKey: key)) ?? nil }
        style = read(FrameStyle.self, .style) ?? style
        finishID = read(String.self, .finishID) ?? finishID
        pose = read(DevicePose.self, .pose) ?? pose
        frameColorID = read(String.self, .frameColorID) ?? frameColorID
        size = read(Double.self, .size) ?? size
        roundness = read(Double.self, .roundness) ?? roundness
        showCamera = read(Bool.self, .showCamera) ?? showCamera
        showButtons = read(Bool.self, .showButtons) ?? showButtons
        browserURL = read(String.self, .browserURL) ?? browserURL
        chromeTheme = read(ChromeTheme.self, .chromeTheme) ?? chromeTheme
        laptopFinishID = read(String.self, .laptopFinishID) ?? laptopFinishID
        showClicks = read(Bool.self, .showClicks) ?? showClicks
    }
}

struct ShadowSettings: Codable, Hashable {
    var enabled = true
    var strength: Double = 0.6
    var softness: Double = 0.55
}

enum TextColorMode: String, Codable, CaseIterable, Identifiable {
    case auto, custom
    var id: String { rawValue }
}

struct TextSettings: Codable, Hashable {
    var title = ""
    var subtitle = ""
    var labelA = "Light"
    var labelB = "Dark"
    var showLabels = true
    var colorMode: TextColorMode = .auto
    var color = RGBAColor(hex: 0x111111)
    var size: Double = 1.0
}

// MARK: - Export

enum ExportQuality: String, Codable, CaseIterable, Identifiable {
    case standard, high
    var id: String { rawValue }
    var label: String { self == .standard ? "Standard" : "High" }

    /// Upload bitrate. X re-encodes everything, so a clean, high-bitrate master gives the best result.
    func bitrate(size: CGSize, fps: Int) -> Int {
        let pixels = Double(size.width * size.height) / (1920.0 * 1080.0)
        let base: Double = self == .standard ? 8_000_000 : 14_000_000
        let fpsFactor = fps > 30 ? 1.5 : 1.0
        return Int(base * max(0.6, pixels) * fpsFactor)
    }
}

enum ImageFormat: String, Codable, CaseIterable, Identifiable {
    case png, jpeg
    var id: String { rawValue }
    var ext: String { self == .png ? "png" : "jpg" }
    var label: String { self == .png ? "PNG" : "JPEG" }
}

enum ExportResolution: String, Codable, CaseIterable, Identifiable {
    case hd1080, qhd1440, uhd4K
    var id: String { rawValue }
    var label: String {
        switch self {
        case .hd1080: "1080p"
        case .qhd1440: "1440p"
        case .uhd4K: "4K"
        }
    }
    var scale: CGFloat {
        switch self {
        case .hd1080: 1
        case .qhd1440: 4.0 / 3.0
        case .uhd4K: 2
        }
    }
}

struct ExportSettings: Codable, Hashable {
    var fps: Int = 60
    var quality: ExportQuality = .high
    var includeAudio = false
    var imageFormat: ImageFormat = .png
    var imageScale: Int = 2
    /// Video size. 4K uploads need X Premium (web or iPhone); X shows everyone else a 1080p version.
    var resolution: ExportResolution = .uhd4K

    /// Output video size for a canvas, rounded to even numbers for the encoder.
    func videoSize(for canvas: CanvasPreset) -> CGSize {
        let base = canvas.size
        func even(_ v: CGFloat) -> CGFloat { (v * resolution.scale / 2).rounded() * 2 }
        return CGSize(width: even(base.width), height: even(base.height))
    }
}

extension ExportSettings {
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func read<T: Decodable>(_ type: T.Type, _ key: CodingKeys) -> T? { (try? c.decodeIfPresent(type, forKey: key)) ?? nil }
        fps = read(Int.self, .fps) ?? fps
        quality = read(ExportQuality.self, .quality) ?? quality
        includeAudio = read(Bool.self, .includeAudio) ?? includeAudio
        imageFormat = read(ImageFormat.self, .imageFormat) ?? imageFormat
        imageScale = read(Int.self, .imageScale) ?? imageScale
        resolution = read(ExportResolution.self, .resolution) ?? resolution
    }
}

// MARK: - Style (the reusable "look")

struct StyleSettings: Codable, Hashable {
    var canvas: CanvasPreset = .portrait
    var background = BackgroundSettings()
    var device = DeviceSettings()
    var shadow = ShadowSettings()
    var text = TextSettings()
    var export = ExportSettings()
    /// Seconds a zoom takes to ease in or out.
    var zoomRamp: Double = 0.55
    /// Automatic zooms on the parts of the screen that change (taps, buttons, typing).
    var autoZoom: AutoZoomLevel = .normal
    /// Playback speed of the recordings (1 = real time).
    var speed: Double = 1
    /// Play moments where nothing changes on screen (loading, waiting) much faster.
    var speedUpPauses = true
    /// Replace the phone's status bar with a clean one (9:41, full battery, no notifications).
    var cleanStatusBar = true

    static let speedOptions: [Double] = [0.5, 1, 1.5, 2, 3]

    var resolvedTextColor: RGBAColor {
        if text.colorMode == .custom { return text.color }
        return background.averageColor.luminance > 0.4 ? RGBAColor(hex: 0x111114) : .white
    }

    private static func defaultsKey(_ platform: Platform) -> String {
        platform == .android ? "PostFrame.style.v2" : "PostFrame.style.web.v1"
    }

    /// A good starting look for each platform.
    static func defaults(for platform: Platform) -> StyleSettings {
        var s = StyleSettings()
        if platform == .web {
            s.canvas = .landscape
            s.background = .gradient(0xF7F8FA, 0xE4E7EE, 180)
            s.device.style = .browser
            s.device.size = 0.9
            s.shadow.strength = 0.55
        }
        return s
    }

    static func load(for platform: Platform = .android) -> StyleSettings {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey(platform)),
              let style = try? JSONDecoder().decode(StyleSettings.self, from: data),
              style.device.style.platform == platform else { return defaults(for: platform) }
        return style
    }

    func save(for platform: Platform = .android) {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey(platform))
        }
    }

    /// Copies the visual look of `other` without touching the text strings or export settings.
    /// Applies a template's look. The canvas is left alone (it's chosen per layout in the toolbar).
    mutating func applyLook(_ other: StyleSettings) {
        background = other.background
        device = other.device
        shadow = other.shadow
        autoZoom = other.autoZoom
        zoomRamp = other.zoomRamp
        text.colorMode = other.text.colorMode
        text.color = other.text.color
        text.size = other.text.size
    }
}

extension StyleSettings {
    /// Tolerant decoding: settings saved by an older version keep everything they have,
    /// and anything new or unreadable falls back to its default.
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func read<T: Decodable>(_ type: T.Type, _ key: CodingKeys) -> T? { (try? c.decodeIfPresent(type, forKey: key)) ?? nil }
        canvas = read(CanvasPreset.self, .canvas) ?? canvas
        background = read(BackgroundSettings.self, .background) ?? background
        device = read(DeviceSettings.self, .device) ?? device
        shadow = read(ShadowSettings.self, .shadow) ?? shadow
        text = read(TextSettings.self, .text) ?? text
        export = read(ExportSettings.self, .export) ?? export
        zoomRamp = read(Double.self, .zoomRamp) ?? zoomRamp
        autoZoom = read(AutoZoomLevel.self, .autoZoom) ?? autoZoom
        speed = read(Double.self, .speed) ?? speed
        speedUpPauses = read(Bool.self, .speedUpPauses) ?? speedUpPauses
        cleanStatusBar = read(Bool.self, .cleanStatusBar) ?? cleanStatusBar
    }
}

/// A named look: built-in or saved by the user.
struct StyleTemplate: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var style: StyleSettings
    var builtIn = false

    var platform: Platform { style.device.style.platform }

    static func builtIns(for platform: Platform) -> [StyleTemplate] {
        platform == .android ? builtIns : webBuiltIns
    }

    /// One-click looks for web apps.
    static let webBuiltIns: [StyleTemplate] = {
        func make(_ name: String, _ bg: BackgroundSettings, frame: FrameStyle = .browser, theme: ChromeTheme = .light,
                  laptop: String = "space-black", pose: DevicePose = .front, shadow: Double = 0.55,
                  zoom: AutoZoomLevel = .normal, size: Double = 0.9) -> StyleTemplate {
            var s = StyleSettings.defaults(for: .web)
            s.background = bg
            s.device.style = frame
            s.device.chromeTheme = theme
            s.device.laptopFinishID = laptop
            s.device.pose = pose
            s.device.size = size
            s.shadow.strength = shadow
            s.autoZoom = zoom
            return StyleTemplate(name: name, style: s, builtIn: true)
        }
        return [
            make("Clean Browser", .gradient(0xF7F8FA, 0xE4E7EE, 180)),
            make("Gradient Browser", .gradient(0x667EEA, 0x764BA2), shadow: 0.75),
            make("Dark Browser", .gradient(0x141E30, 0x243B55, 160), theme: .dark, shadow: 0.9),
            make("Peach Browser", .gradient(0xFFECD2, 0xFCB69F), shadow: 0.6),
            make("MacBook Studio", .gradient(0xF7F8FA, 0xE4E7EE, 180), frame: .macbook3D, laptop: "silver", size: 0.95),
            make("MacBook Hero", .gradient(0x4FACFE, 0x00F2FE), frame: .macbook3D, pose: .angled, shadow: 0.7, size: 0.95),
            make("MacBook Night", .radial(0x30343F, 0x0A0B0E), frame: .macbook3D, laptop: "space-black", pose: .hero, shadow: 0.9, size: 0.95),
            make("Window", .gradient(0xFBC2EB, 0xA6C1EE), frame: .window, shadow: 0.7),
            make("Board", .solid(0xEDEDEB), frame: .window, shadow: 0.5),
        ]
    }()

    private static let defaultsKey = "PostFrame.templates.v1"

    /// One-click looks. Each one sets everything (background, phone, angle, shadow, zoom style, canvas).
    static let builtIns: [StyleTemplate] = {
        func make(_ name: String, _ bg: BackgroundSettings, finish: String = "ti-black", pose: DevicePose = .front,
                  frame: FrameStyle = .galaxy3D, canvas: CanvasPreset = .portrait, shadow: Double = 0.6,
                  zoom: AutoZoomLevel = .normal) -> StyleTemplate {
            var s = StyleSettings()
            s.canvas = canvas
            s.background = bg
            s.device.style = frame
            s.device.finishID = finish
            s.device.pose = pose
            s.shadow.strength = shadow
            s.autoZoom = zoom
            return StyleTemplate(name: name, style: s, builtIn: true)
        }
        return [
            make("Studio", .gradient(0xF7F8FA, 0xE4E7EE, 180), shadow: 0.55),
            make("Board", .solid(0xEDEDEB), finish: "ti-whitesilver", shadow: 0.5, zoom: .normal),
            make("Hero", .gradient(0x667EEA, 0x764BA2), finish: "ti-whitesilver", pose: .hero, shadow: 0.8),
            make("Float", .gradient(0xFBC2EB, 0xA6C1EE), finish: "ti-silverblue", pose: .float, shadow: 0.7),
            make("Angled", .gradient(0xFFECD2, 0xFCB69F), finish: "ti-gray", pose: .angled, shadow: 0.65),
            make("Midnight", .gradient(0x141E30, 0x243B55, 160), finish: "ti-whitesilver", shadow: 0.9, zoom: .punchy),
            make("App Glow", BackgroundPreset.all.last!.settings, finish: "ti-black", pose: .float, shadow: 0.85),
            make("Ocean", .gradient(0x4FACFE, 0x00F2FE), finish: "ti-black", pose: .angled, shadow: 0.7),
            make("Clean White", .solid(0xFFFFFF), finish: "ti-black", shadow: 0.45, zoom: .subtle),
            make("Flat Minimal", .gradient(0xFBF6EE, 0xEEE2CF, 160), frame: .screenOnly, shadow: 0.7, zoom: .subtle),
            make("Spotlight", .radial(0x30343F, 0x0A0B0E), finish: "ti-gray", pose: .hero, shadow: 0.9),
        ]
    }()

    /// Built-in look for side-by-side comparisons (no zoom: both phones stay fully visible).
    static let compareDefault: StyleTemplate = {
        var s = StyleSettings()
        s.canvas = .landscape
        s.background = .gradient(0xF7F8FA, 0xE4E7EE, 180)
        s.device.style = .galaxy3D
        s.device.pose = .angled
        s.autoZoom = .off
        return StyleTemplate(name: "Compare", style: s, builtIn: true)
    }()

    init(id: UUID = UUID(), name: String, style: StyleSettings, builtIn: Bool = false) {
        self.id = id; self.name = name; self.style = style; self.builtIn = builtIn
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        style = try c.decode(StyleSettings.self, forKey: .style)
        builtIn = (try? c.decode(Bool.self, forKey: .builtIn)) ?? false
    }

    static func loadSaved() -> [StyleTemplate] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let list = try? JSONDecoder().decode([StyleTemplate].self, from: data) else { return [] }
        return list
    }

    static func saveAll(_ list: [StyleTemplate]) {
        if let data = try? JSONEncoder().encode(list.filter { !$0.builtIn }) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}

// MARK: - Zoom

struct ZoomSegment: Codable, Hashable, Identifiable {
    var id = UUID()
    var start: Double
    var end: Double
    var scale: Double = 1.8
    /// Zoom target in canvas space, 0…1 from the top-left (used when there's no screen anchor).
    var focusX: Double = 0.5
    var focusY: Double = 0.4
    /// Auto-zooms are pinned to a spot on a phone's screen (0…1 across/down), so they stay on target
    /// whatever template, canvas or 3D angle you pick.
    var anchorSlot: Int?
    var anchorU: Double = 0.5
    var anchorV: Double = 0.5
    var isAuto = false

    var duration: Double { end - start }
}

enum AutoZoomLevel: String, Codable, CaseIterable, Identifiable {
    case off, subtle, normal, punchy
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: "Off"
        case .subtle: "Subtle"
        case .normal: "Normal"
        case .punchy: "Punchy"
        }
    }
    var scale: Double {
        switch self {
        case .off: 1
        case .subtle: 1.45
        case .normal: 1.8
        case .punchy: 2.3
        }
    }
}
