import AppKit
import ScreenCaptureKit

/// `AppX Motion render --a clip.mp4 [--b clip2.mp4] --out post.mp4 [options]`
///
/// Options: --canvas landscape|square|portrait|tall|story   --bg <preset id>   --frame phone|minimal|screenOnly
///          --color <frame colour id>   --title "…"   --subtitle "…"   --labels "Light,Dark"
///          --zoom start:end:scale:focusX:focusY (repeatable)   --fps 30|60   --time <s> (PNG of one moment)
///          --offset-b <s>   --scale 1|2
enum HeadlessCLI {
    static func handles(_ args: [String]) -> Bool {
        args.count > 1 && ["render", "device-test", "capture-test", "project-check"].contains(args[1])
    }

    static func run(_ args: [String]) -> Int32 {
        if args[1] == "device-test" { return deviceTest(serial: args.count > 2 ? args[2] : nil) }
        if args[1] == "project-check", args.count > 2 {
            do {
                let project = try ProjectFile.read(from: URL(fileURLWithPath: args[2]))
                let files = project.media.map { $0.map { ($0.path as NSString).lastPathComponent } ?? "(empty)" }
                print("✓ \(project.platform.rawValue) · \(project.layout.rawValue) · \(project.style.device.style.rawValue) · \(project.style.speed)× · \(project.style.canvas.ratio) · \(files.joined(separator: " | "))")
                return 0
            } catch {
                print("✗ \(error)")
                return 1
            }
        }
        if args[1] == "capture-test" { return captureTest(output: args.count > 2 ? args[2] : NSTemporaryDirectory() + "postframe-capture-test.mp4") }
        var options: [String: [String]] = [:]
        var i = 2
        while i < args.count {
            let key = args[i]
            if key.hasPrefix("--"), i + 1 < args.count {
                options[String(key.dropFirst(2)), default: []].append(args[i + 1])
                i += 2
            } else {
                i += 1
            }
        }
        func value(_ key: String) -> String? { options[key]?.last }

        let tourFiles = value("tour")?.split(separator: ",").map(String.init) ?? []
        guard let a = value("a") ?? tourFiles.first, let out = value("out") else {
            FileHandle.standardError.write(Data("usage: AppX Motion render --a <file> [--b <file>] --out <file.mp4|png> [options]\n".utf8))
            return 2
        }

        var style = StyleSettings()
        if let canvas = value("canvas").flatMap(CanvasPreset.init(rawValue:)) { style.canvas = canvas }
        if let id = value("bg"), let preset = BackgroundPreset.all.first(where: { $0.id == id }) { style.background = preset.settings }
        if let frame = value("frame").flatMap(FrameStyle.init(rawValue:)) { style.device.style = frame }
        if let color = value("color") { style.device.frameColorID = color }
        if let finish = value("finish") { style.device.finishID = finish }
        if let pose = value("pose").flatMap(DevicePose.init(rawValue:)) { style.device.pose = pose }
        if let shadow = value("shadow").flatMap(Double.init) { style.shadow.strength = shadow }
        if let speed = value("speed").flatMap(Double.init) { style.speed = speed }
        if let url = value("url") { style.device.browserURL = url }
        if let clean = value("statusbar") { style.cleanStatusBar = clean != "original" }
        if value("chrome") == "dark" { style.device.chromeTheme = .dark }
        if let laptop = value("laptop") { style.device.laptopFinishID = laptop }
        if style.device.style.platform == .web && value("canvas") == nil { style.canvas = .landscape }
        style.speedUpPauses = value("pauses") == "fast"
        if let level = value("autozoom").flatMap(AutoZoomLevel.init(rawValue:)) { style.autoZoom = level }
        if let title = value("title") { style.text.title = title }
        if let subtitle = value("subtitle") { style.text.subtitle = subtitle }
        if let labels = value("labels")?.split(separator: ",").map(String.init), labels.count == 2 {
            style.text.labelA = labels[0]; style.text.labelB = labels[1]
        }
        if let fps = value("fps").flatMap(Int.init) { style.export.fps = fps }
        if let scale = value("scale").flatMap(Int.init) { style.export.imageScale = scale }
        let outURL = URL(fileURLWithPath: out)
        style.export.imageFormat = outURL.pathExtension.lowercased() == "jpg" ? .jpeg : .png

        let zooms: [ZoomSegment] = (options["zoom"] ?? []).compactMap { spec in
            let p = spec.split(separator: ":").compactMap { Double($0) }
            guard p.count == 5 else { return nil }
            return ZoomSegment(start: p[0], end: p[1], scale: p[2], focusX: p[3], focusY: p[4])
        }

        let semaphore = DispatchSemaphore(value: 0)
        var status: Int32 = 0
        Task.detached {
            do {
                var itemA = try await MediaItem.load(URL(fileURLWithPath: a))
                if let crop = value("crop").flatMap(Double.init) { itemA.cropTop = CGFloat(crop) }
                var itemB: MediaItem?
                if let b = value("b") { itemB = try await MediaItem.load(URL(fileURLWithPath: b)) }
                let compare = itemB != nil
                var allZooms = zooms
                var timeMaps: [TimeMap?] = []
                if itemA.isVideo, !compare, style.autoZoom != .off || style.speedUpPauses || style.speed != 1 {
                    let events = try await AutoZoom.detectEvents(url: itemA.url, offset: 0, phone: style.device.style.platform == .android)
                    let idle = style.speedUpPauses ? AutoZoom.idleSpans(from: events, length: itemA.duration) : []
                    let map = TimeMap.make(length: itemA.duration, speed: style.speed, idle: idle)
                    timeMaps = [map.isIdentity ? nil : map]
                    if !map.isIdentity { print(String(format: "speed: %.1fs → %.1fs", itemA.duration, map.duration)) }
                    if style.autoZoom != .off {
                        let mapped = events.map { AutoZoom.Event(time: map.output(at: $0.time), u: $0.u, v: $0.v, area: $0.area, weight: $0.weight, isGlobal: $0.isGlobal) }
                        let found = AutoZoom.segments(from: mapped, level: style.autoZoom, slot: 0, ramp: style.zoomRamp, duration: map.duration)
                        print("auto-zoom: " + found.map { String(format: "%.1f–%.1fs %.1f× at (%.2f, %.2f)", $0.start, $0.end, $0.scale, $0.anchorU, $0.anchorV) }.joined(separator: "; "))
                        allZooms += found
                    }
                } else if compare && style.speed != 1 {
                    timeMaps = [itemA, itemB].map { item in item.flatMap { $0.isVideo ? TimeMap.make(length: $0.duration, speed: style.speed) : nil } }
                }
                var job = RenderJob(style: style, mode: compare ? .compare : .single, slots: compare ? [itemA, itemB] : [itemA],
                                    offsets: [0, value("offset-b").flatMap(Double.init) ?? 0], zooms: allZooms, timeMaps: timeMaps)
                if tourFiles.count > 1 {
                    var items: [MediaItem?] = []
                    for file in tourFiles { items.append(try await MediaItem.load(URL(fileURLWithPath: file))) }
                    job = RenderJob(style: style, mode: .tour, slots: items, offsets: items.map { _ in 0 })
                    print("tour: " + String(format: "%.1fs", job.tour?.total ?? 0))
                }
                let start = Date()
                if ["png", "jpg"].contains(outURL.pathExtension.lowercased()) {
                    if job.producesVideo {
                        try await ExportEngine.exportFrame(job: job, time: value("time").flatMap(Double.init) ?? 0, to: outURL)
                    } else {
                        try ExportEngine.exportStill(job: job, to: outURL)
                    }
                } else {
                    let last = ProgressPrinter()
                    try await ExportEngine.exportVideo(job: job, to: outURL) { p in last.report(p) }
                }
                print(String(format: "Wrote %@ in %.1fs", outURL.path, Date().timeIntervalSince(start)))
            } catch {
                FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
                status = 1
            }
            semaphore.signal()
        }
        semaphore.wait()
        return status
    }
}

private final class ProgressPrinter: @unchecked Sendable {
    private var last = -1
    func report(_ p: Double) {
        let decile = Int(p * 10)
        if decile != last { last = decile; print("  \(decile * 10)%") }
    }
}

// MARK: - Device self-test (exercises the same code paths the app uses)

extension HeadlessCLI {
    static func deviceTest(serial: String?) -> Int32 {
        let semaphore = DispatchSemaphore(value: 0)
        var status: Int32 = 0
        Task.detached {
            func step(_ name: String, _ body: () async throws -> String) async {
                do { print("✓ \(name): \(try await body())") } catch { print("✗ \(name): \(error.localizedDescription)"); status = 1 }
            }
            guard let adbPath = ToolLocator.adb else { print("✗ adb not found"); status = 1; semaphore.signal(); return }
            print("adb: \(adbPath)  scrcpy: \(ToolLocator.scrcpy ?? "missing")")
            let list = (try? await Shell.run(adbPath, ["devices", "-l"]).out) ?? ""
            let devices = AndroidDevice.parse(list)
            print("devices: \(devices.map { "\($0.displayName) [\($0.state)]" })")
            guard let device = devices.first(where: { $0.isReady && (serial == nil || $0.serial == serial) }) else {
                print("✗ no ready device"); status = 1; semaphore.signal(); return
            }
            let adb = ADB(path: adbPath, serial: device.serial)
            let out = Paths.captures

            await step("screencap") {
                let data = try await adb.screencap()
                let url = out.appendingPathComponent("selftest-shot.png"); try data.write(to: url)
                let item = try await MediaItem.load(url)
                return "\(data.count) bytes, \(Int(item.pixelSize.width))×\(Int(item.pixelSize.height))"
            }
            var original: String?
            await step("night mode read") { original = await adb.nightMode(); return original ?? "nil" }
            await step("night mode → yes") { try await adb.setNightMode("yes"); try await Task.sleep(for: .seconds(1)); return await adb.nightMode() ?? "nil" }
            await step("night mode → no") { try await adb.setNightMode("no"); return await adb.nightMode() ?? "nil" }
            if let original { try? await adb.setNightMode(original) }
            await step("demo mode on") { try await adb.setDemoMode(true); return "ok" }
            await step("demo screenshot") {
                let data = try await adb.screencap()
                try data.write(to: out.appendingPathComponent("selftest-demo.png")); return "\(data.count) bytes"
            }
            await step("demo mode off") { try await adb.setDemoMode(false); return "ok" }
            await step("recent media") {
                let items = try await adb.recentMedia()
                return "\(items.count) found" + (items.first.map { ", newest: \($0.name)" } ?? "")
            }
            if let scrcpy = ToolLocator.scrcpy {
                await step("scrcpy record 12s") {
                    let url = Paths.unique(out.appendingPathComponent("selftest-recording.mp4"))
                    var options = CaptureOptions(); options.showMirror = false; options.showTouches = false
                    let session = try ScrcpySession(scrcpy: scrcpy, adb: adbPath, serial: device.serial, output: url, options: options)
                    let exited = OnceFlag()
                    session.onExit = { _ in _ = exited.set() }
                    try await Task.sleep(for: .seconds(12))
                    print("    scrcpy log: \(session.fullLog.split(separator: "\n").suffix(4).joined(separator: " | "))")
                    session.stop()
                    for _ in 0..<40 where session.isRunning { try await Task.sleep(for: .milliseconds(250)) }
                    let item = try await MediaItem.load(url)
                    return String(format: "%.1fs, %d×%d → %@", item.duration, Int(item.pixelSize.width), Int(item.pixelSize.height), url.lastPathComponent)
                }
            }
            semaphore.signal()
        }
        semaphore.wait()
        return status
    }
}

// MARK: - Window capture self-test (records a throwaway test window, never your own windows)

extension HeadlessCLI {
    final class TestView: NSView {
        var phase: CGFloat = 0
        override func draw(_ dirtyRect: NSRect) {
            NSColor(srgbRed: 0.97, green: 0.97, blue: 0.99, alpha: 1).setFill()
            bounds.fill()
            NSColor(srgbRed: 0.31, green: 0.27, blue: 0.9, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: 40 + phase, y: 150, width: 160, height: 100), xRadius: 16, yRadius: 16).fill()
        }
    }

    static func captureTest(output: String) -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 640, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "AppX Motion capture test"
        let view = TestView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        window.contentView = view
        window.orderFrontRegardless()
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { _ in
            view.phase = (view.phase + 6).truncatingRemainder(dividingBy: 400)
            view.needsDisplay = true
        }
        RunLoop.main.add(timer, forMode: .common)

        Task { @MainActor in
            func finish(_ code: Int32) { window.close(); exit(code) }
            do {
                try await Task.sleep(for: .seconds(1))
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                guard let target = content.windows.first(where: { $0.title == "AppX Motion capture test" }) else {
                    print("✗ test window not visible to ScreenCaptureKit"); return finish(1)
                }
                // Screenshot
                let filter = SCContentFilter(desktopIndependentWindow: target)
                let config = SCStreamConfiguration()
                config.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
                config.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
                let shot = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                print("✓ screenshot \(shot.width)×\(shot.height)")
                // Recording
                let url = URL(fileURLWithPath: output)
                try? FileManager.default.removeItem(at: url)
                let info = CapturableWindow(id: target.windowID, title: target.title ?? "", appName: "Test", bundleID: "test", frame: target.frame)
                let recording = try WindowRecording(window: target, info: info, url: url, showCursor: false, hideBrowserBar: false)
                recording.onFinish = { result in
                    Task { @MainActor in
                        switch result {
                        case .success(let url):
                            let item = try? await MediaItem.load(url)
                            print(String(format: "✓ recording %@: %.1fs %d×%d, sidecar %@", url.lastPathComponent, item?.duration ?? 0,
                                         Int(item?.pixelSize.width ?? 0), Int(item?.pixelSize.height ?? 0),
                                         FileManager.default.fileExists(atPath: MediaItem.sidecarURL(for: url).path) ? "written" : "missing"))
                            finish(0)
                        case .failure(let error):
                            print("✗ recording failed: \(error.localizedDescription)"); finish(1)
                        }
                    }
                }
                try await recording.start()
                try await Task.sleep(for: .seconds(3))
                await recording.stop()
                try await Task.sleep(for: .seconds(10))
                print("✗ recording never finished"); finish(1)
            } catch {
                print("✗ \(error.localizedDescription)"); finish(1)
            }
        }
        app.run()
        return 0
    }
}
