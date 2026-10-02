import AppKit
import AVFoundation
import Observation
import UniformTypeIdentifiers

struct Banner: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var isError: Bool
}

enum ExportPhase: Equatable {
    case idle
    case running(Double)
    case done
}

struct ExportResult: Identifiable {
    let id = UUID()
    let url: URL
    let thumbnail: NSImage?
    let isVideo: Bool
    let bytes: Int64
    let pixelSize: CGSize
    let duration: Double?
}

@Observable @MainActor
final class AppModel {
    // MARK: Document state

    /// Android app or web app. Each has its own workspace, look and templates.
    private(set) var platform: Platform = Platform(rawValue: UserDefaults.standard.string(forKey: "PostFrame.platform") ?? "") ?? .android
    var style: StyleSettings = .load(for: Platform(rawValue: UserDefaults.standard.string(forKey: "PostFrame.platform") ?? "") ?? .android) {
        didSet { if !switchingPlatform { styleChanged(from: oldValue) } }
    }
    var layout: LayoutMode = .single {
        didSet { if layout != oldValue && !switchingPlatform { layoutChanged() } }
    }
    /// Media per phone. Single uses slot 0, compare slots 0–1, tour uses all of them in order.
    private(set) var slots: [MediaItem?] = [nil, nil]
    /// Seconds skipped at the start of each slot's clip (to line up two takes).
    var offsets: [Double] = [0, 0] {
        didSet { if offsets != oldValue && !switchingPlatform { offsetsChanged() } }
    }
    /// Slot that captures and imports go into.
    var selectedSlot = 0
    var zooms: [ZoomSegment] = [] {
        didSet {
            guard zooms != oldValue, !switchingPlatform else { return }
            scheduleRenderer()
            if zooms.filter({ !$0.isAuto }) != oldValue.filter({ !$0.isAuto }) { scheduleAutosave() }
        }
    }
    var selectedZoomID: UUID? {
        didSet { if selectedZoomID != oldValue { scheduleRenderer() } }
    }
    var trimIn: Double = 0 { didSet { updateLoop(); scheduleAutosave() } }
    var trimOut: Double = 0 { didSet { updateLoop(); scheduleAutosave() } }

    // MARK: UI state

    private(set) var stillPreview: CGImage?
    private(set) var filmstrip: [NSImage] = []
    private(set) var templatePreviews: [String: CGImage] = [:]
    private(set) var analyzingZoom = false
    var activeTemplateName: String = "" {
        didSet { UserDefaults.standard.set(activeTemplateName, forKey: "PostFrame.template.\(platform.rawValue)") }
    }
    var banner: Banner?
    var exportPhase: ExportPhase = .idle
    var lastExport: ExportResult?
    var showExportSheet = false
    var showImporter = false
    var showPhoneGallery = false
    var phoneGallery: [RemoteMedia] = []
    var loadingGallery = false
    var isImporting = false
    var templates: [StyleTemplate] = StyleTemplate.loadSaved()
    /// Guided "record light take, then dark take" flow.
    private(set) var pairStage: PairStage?

    enum PairStage { case light, dark }

    let playback = PlaybackController()
    let device = DeviceController()
    let macCapture = MacCapture()
    private let previewBox = RenderBox()
    private let recordingPill = RecordingPill()

    /// What's loaded in the other platform's workspace, kept while you switch back and forth.
    private struct Workspace {
        var layout: LayoutMode = .single
        var slots: [MediaItem?] = [nil, nil]
        var offsets: [Double] = [0, 0]
        var zooms: [ZoomSegment] = []
        var selectedSlot = 0
    }
    @ObservationIgnored private var workspaces: [Platform: Workspace] = [:]
    @ObservationIgnored private var switchingPlatform = false
    @ObservationIgnored private var restoring = false
    @ObservationIgnored private var autosaveTask: Task<Void, Never>?
    /// Trim to re-apply once a restored project's timeline is built.
    @ObservationIgnored private var pendingTrim: (Double, Double)?
    /// File the current project was last saved to or opened from.
    var projectURL: URL?

    @ObservationIgnored private var rendererBusy = false
    @ObservationIgnored private var rendererDirty = false
    @ObservationIgnored private var compositionTask: Task<Void, Never>?
    @ObservationIgnored private var offsetsTask: Task<Void, Never>?
    @ObservationIgnored private var cropTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var bannerTask: Task<Void, Never>?
    @ObservationIgnored private var previewsTask: Task<Void, Never>?
    @ObservationIgnored private var autoZoomTask: Task<Void, Never>?
    @ObservationIgnored private var motionCache: [URL: [AutoZoom.Event]] = [:]
    /// Time maps the current preview composition was built with (to keep manual zooms on the same moments).
    @ObservationIgnored private var builtTimeMaps: [TimeMap?] = []
    @ObservationIgnored private var exportToken: CancelToken?
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var pairOriginalMode: String?
    @ObservationIgnored private var started = false

    // MARK: Derived

    var compare: Bool { layout == .compare }
    var tour: Bool { layout == .tour }
    var activeSlots: [MediaItem?] {
        switch layout {
        case .single: return [slots.first ?? nil]
        case .compare: return [slots.first ?? nil, slots.count > 1 ? slots[1] : nil]
        case .tour: return slots.filter { $0 != nil }
        }
    }
    var activeOffsets: [Double] {
        switch layout {
        case .tour: return slots.indices.filter { slots[$0] != nil }.map { $0 < offsets.count ? offsets[$0] : 0 }
        default: return offsets
        }
    }
    var hasContent: Bool { activeSlots.contains { $0 != nil } }
    var hasVideo: Bool { activeSlots.contains { $0?.isVideo == true } }
    /// Renders as a moving video (videos, and tours even when made of screenshots).
    var isMotion: Bool { hasVideo || (tour && hasContent) }
    var isStill: Bool { hasContent && !isMotion }
    var hasAudio: Bool { activeSlots.contains { $0?.hasAudio == true } }
    var selectedZoom: ZoomSegment? { zooms.first { $0.id == selectedZoomID } }
    var currentLayout: SceneLayout? { previewBox.renderer?.layout }
    var isExporting: Bool { if case .running = exportPhase { return true }; return false }
    var allTemplates: [StyleTemplate] { StyleTemplate.builtIns(for: platform) + templates.filter { $0.platform == platform } }
    var isWeb: Bool { platform == .web }
    var isRecordingAnything: Bool { device.isRecording || macCapture.isRecording }

    /// Speed + sped-up pauses for each active slot. Pauses are only sped up when clips don't need to stay in sync.
    var activeTimeMaps: [TimeMap?] {
        let offs = activeOffsets
        return activeSlots.enumerated().map { i, item in
            guard let item, item.isVideo else { return nil }
            let offset = i < offs.count ? offs[i] : 0
            let length = max(0.05, item.duration - offset)
            var idle: [ClosedRange<Double>] = []
            if style.speedUpPauses && !compare, let events = motionCache[item.url] {
                let shifted = events.compactMap { e -> AutoZoom.Event? in
                    e.time < offset ? nil : AutoZoom.Event(time: e.time - offset, u: e.u, v: e.v, area: e.area, weight: e.weight, isGlobal: e.isGlobal)
                }
                idle = AutoZoom.idleSpans(from: shifted, length: length)
            }
            let map = TimeMap.make(length: length, speed: style.speed, idle: idle)
            return map.isIdentity ? nil : map
        }
    }

    /// Length of the recording before and after speed changes (for the UI).
    var speedSummary: (original: Double, result: Double)? {
        guard hasVideo, !tour, let index = activeSlots.firstIndex(where: { $0?.isVideo == true }), let item = activeSlots[index] else { return nil }
        let offset = index < activeOffsets.count ? activeOffsets[index] : 0
        let original = max(0, item.duration - offset)
        let maps = activeTimeMaps
        let result = (index < maps.count ? maps[index] : nil)?.duration ?? original
        return (original, result)
    }

    func viewport(for zoom: ZoomSegment) -> CGRect? { previewBox.renderer?.viewport(for: zoom) }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        activeTemplateName = UserDefaults.standard.string(forKey: "PostFrame.template.\(platform.rawValue)")
            ?? StyleTemplate.builtIns(for: platform).first?.name ?? ""
        device.startMonitoring()
        installKeyMonitor()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.writeSession()
                self?.device.shutdown()
            }
        }
        scheduleRenderer()
        refreshTemplatePreviews()
        restoreSession(for: platform)

        // Files to open at launch: `open AppX Motion.app --env APPXMOTION_OPEN="a.mp4|b.mp4"`.
        // (Passing them as plain arguments makes AppKit treat them as documents and skip the main window.)
        let files = (ProcessInfo.processInfo.environment["APPXMOTION_OPEN"] ?? "")
            .split(separator: "|").map(String.init)
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
        if !files.isEmpty { importURLs(files) }
        if let script = ProcessInfo.processInfo.environment["APPXMOTION_DEBUG"] { runDebugScript(script) }
    }

    /// Test hook used during development: `APPXMOTION_DEBUG="wait:2,zoom:1,select:none,seek:1.6,export"`.
    private func runDebugScript(_ script: String) {
        Task {
            for step in script.split(separator: ",") {
                let parts = step.split(separator: ":").map(String.init)
                let arg = parts.count > 1 ? Double(parts[1]) : nil
                switch parts[0] {
                case "wait": try? await Task.sleep(for: .seconds(arg ?? 1))
                case "zoom": addZoom(at: arg)
                case "select": selectedZoomID = parts.last == "none" ? nil : zooms.first?.id
                case "seek": playback.seek(to: arg ?? 0)
                case "play": playback.play()
                case "title": style.text.title = parts.dropFirst().joined(separator: ":")
                case "canvas": if let c = CanvasPreset(rawValue: parts.last ?? "") { style.canvas = c }
                case "look": if let t = allTemplates.first(where: { $0.name == parts.last }) { applyTemplate(t) }
                case "frame": if let f = FrameStyle(rawValue: parts.last ?? "") { style.device.style = f }
                case "export": export()
                case "layout": layout = LayoutMode(rawValue: parts.last ?? "") ?? .single
                default: break
                }
            }
        }
    }

    // MARK: Platform

    /// Switches between the Android and web workspaces. Each keeps its own media, look and templates.
    func switchPlatform(to newPlatform: Platform) {
        guard newPlatform != platform, !isRecordingAnything, !isExporting else { return }
        playback.pause()
        style.save(for: platform)
        writeSession()
        workspaces[platform] = Workspace(layout: layout, slots: slots, offsets: offsets, zooms: zooms, selectedSlot: selectedSlot)

        switchingPlatform = true
        templatePreviews = [:]
        platform = newPlatform
        UserDefaults.standard.set(newPlatform.rawValue, forKey: "PostFrame.platform")
        style = .load(for: newPlatform)
        let workspace = workspaces[newPlatform] ?? Workspace()
        layout = workspace.layout
        slots = workspace.slots
        offsets = workspace.offsets
        zooms = workspace.zooms
        selectedSlot = workspace.selectedSlot
        selectedZoomID = nil
        activeTemplateName = UserDefaults.standard.string(forKey: "PostFrame.template.\(newPlatform.rawValue)")
            ?? StyleTemplate.builtIns(for: newPlatform).first?.name ?? ""
        switchingPlatform = false

        rebuildComposition(resetTrim: true)
        scheduleRenderer()
        makeFilmstrip()
        refreshTemplatePreviews()
        refreshAutoZoom()
        if newPlatform == .web { refreshMacWindows() }
        if workspaces[newPlatform] == nil { restoreSession(for: newPlatform) }
    }

    // MARK: Projects (autosave, open, save)

    func currentProject() -> ProjectFile {
        ProjectFile(platform: platform, layout: layout, style: style,
                    media: slots.map { item in item.map { ProjectFile.Media(path: $0.url.path, cropTop: Double($0.cropTop)) } },
                    offsets: offsets, zooms: zooms.filter { !$0.isAuto },
                    trimIn: trimIn, trimOut: trimOut, templateName: activeTemplateName)
    }

    /// Saves the current workspace a second after the last change, so nothing is lost if the app quits.
    private func scheduleAutosave() {
        guard started, !restoring, !switchingPlatform else { return }
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.writeSession()
        }
    }

    private func writeSession() {
        let project = currentProject()
        try? project.write(to: ProjectFile.sessionURL(project.platform))
        if let projectURL { try? project.write(to: projectURL) }
    }

    private func restoreSession(for platform: Platform) {
        let url = ProjectFile.sessionURL(platform)
        guard let project = try? ProjectFile.read(from: url), project.platform == platform,
              project.media.contains(where: { $0 != nil }) else { return }
        Task { await apply(project) }
    }

    /// Loads a project: its look, media, zooms and trim.
    func apply(_ project: ProjectFile) async {
        if project.platform != platform { switchPlatform(to: project.platform) }
        restoring = true
        isImporting = true
        var items: [MediaItem?] = []
        var missing: [String] = []
        for entry in project.media {
            guard let entry else { items.append(nil); continue }
            // Captures moved into ~/Movies/AppX Motion when the app was renamed.
            var path = entry.path
            if !FileManager.default.fileExists(atPath: path) {
                for old in Migration.oldFolderNames {
                    let moved = path.replacingOccurrences(of: "/Movies/\(old)/", with: "/Movies/AppX Motion/")
                    if FileManager.default.fileExists(atPath: moved) { path = moved; break }
                }
            }
            guard FileManager.default.fileExists(atPath: path), var item = try? await MediaItem.load(URL(fileURLWithPath: path)) else {
                missing.append((entry.path as NSString).lastPathComponent)
                items.append(nil)
                continue
            }
            item.cropTop = CGFloat(entry.cropTop)
            items.append(item)
        }
        switchingPlatform = true
        style = project.style
        layout = project.layout
        slots = items.isEmpty ? [nil, nil] : items
        while slots.count < 2 && layout != .tour { slots.append(nil) }
        offsets = slots.indices.map { $0 < project.offsets.count ? project.offsets[$0] : 0 }
        zooms = project.zooms
        selectedSlot = 0
        selectedZoomID = nil
        if let name = project.templateName { activeTemplateName = name }
        switchingPlatform = false
        if let a = project.trimIn, let b = project.trimOut, b > a { pendingTrim = (a, b) }
        isImporting = false
        restoring = false

        rebuildComposition(resetTrim: true)
        scheduleRenderer()
        makeFilmstrip()
        refreshTemplatePreviews()
        refreshAutoZoom()
        if !missing.isEmpty {
            show("Couldn't find: \(missing.joined(separator: ", ")). It may have been moved or deleted.", error: true)
        }
    }

    func newProject() {
        guard !isRecordingAnything else { return }
        playback.pause()
        projectURL = nil
        slots = layout == .tour ? [] : [nil, nil]
        offsets = slots.map { _ in 0 }
        zooms = []
        selectedZoomID = nil
        style.text.title = ""
        style.text.subtitle = ""
        mediaChanged()
    }

    func saveProjectAs() {
        let panel = NSSavePanel()
        panel.directoryURL = ProjectFile.projectsFolder
        panel.allowedContentTypes = [UTType(filenameExtension: ProjectFile.fileExtension) ?? .json]
        let title = style.text.title.trimmingCharacters(in: .whitespacesAndNewlines)
        panel.nameFieldStringValue = title.isEmpty ? "AppX Motion project" : title
        panel.message = "Saves your screens, look, zooms and trim. Your recordings stay where they are."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try currentProject().write(to: url)
            projectURL = url
            show("Saved \(url.deletingPathExtension().lastPathComponent)")
        } catch {
            show(error)
        }
    }

    func saveProject() {
        guard let projectURL else { return saveProjectAs() }
        do {
            try currentProject().write(to: projectURL)
            show("Saved \(projectURL.deletingPathExtension().lastPathComponent)")
        } catch {
            show(error)
        }
    }

    func openProject() {
        let panel = NSOpenPanel()
        panel.directoryURL = ProjectFile.projectsFolder
        panel.allowedContentTypes = ([ProjectFile.fileExtension] + ProjectFile.legacyExtensions).compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openProject(at: url)
    }

    func openProject(at url: URL) {
        do {
            let project = try ProjectFile.read(from: url)
            projectURL = url
            Task { await apply(project) }
        } catch {
            show("Couldn't open that project: \(error.localizedDescription)", error: true)
        }
    }

    // MARK: Messages

    func show(_ text: String, error: Bool = false) {
        banner = Banner(text: text, isError: error)
        bannerTask?.cancel()
        bannerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(error ? 7 : 3.5))
            if !Task.isCancelled { self?.banner = nil }
        }
    }

    func show(_ error: Error) {
        if case ExportError.cancelled = error { return }
        show(error.localizedDescription, error: true)
    }

    // MARK: Media

    func importURLs(_ urls: [URL]) {
        let media = urls.filter { url in
            guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
            return type.conforms(to: .movie) || type.conforms(to: .image) || type.conforms(to: .video)
        }
        guard !media.isEmpty else {
            show("Drop a video or image file.", error: true)
            return
        }
        Task {
            if media.count >= 3 || (tour && hasContent) {
                // Several screens → a camera tour.
                if !tour {
                    slots = []
                    offsets = []
                    enter(.tour)
                }
                for url in media { await importMedia(url, into: slots.count) }
            } else if media.count == 2 {
                enter(.compare)
                await importMedia(media[0], into: 0)
                await importMedia(media[1], into: 1)
            } else {
                await importMedia(media[0], into: selectedSlot)
            }
        }
    }

    /// Switches layout and picks a sensible canvas for it.
    private func enter(_ mode: LayoutMode) {
        guard layout != mode else { return }
        layout = mode
        switch mode {
        case _ where isWeb:
            if style.canvas != .landscape && style.canvas != .square { style.canvas = .landscape }
        case .compare where style.canvas != .landscape && style.canvas != .square:
            style.canvas = .landscape
            if style.autoZoom != .off { style.autoZoom = .off }
        case .tour where style.canvas != .square && style.canvas != .landscape:
            style.canvas = .square
        default:
            break
        }
    }

    func importMedia(_ url: URL, into slot: Int) async {
        isImporting = true
        defer { isImporting = false }
        do {
            let item = try await MediaItem.load(url)
            while slots.count <= slot { slots.append(nil) }
            while offsets.count < slots.count { offsets.append(0) }
            slots[slot] = item
            offsets[slot] = 0
            if slot == 1 && layout == .single { enter(.compare) }
            if compare && slot == 0 && slots[1] == nil { selectedSlot = 1 }
            mediaChanged()
        } catch {
            show(error)
        }
    }

    func clearSlot(_ slot: Int) {
        guard slot < slots.count else { return }
        if tour {
            slots.remove(at: slot)
            if slot < offsets.count { offsets.remove(at: slot) }
        } else {
            slots[slot] = nil
            offsets[slot] = 0
        }
        mediaChanged()
    }

    func moveSlot(_ from: Int, by delta: Int) {
        let to = from + delta
        guard slots.indices.contains(from), slots.indices.contains(to) else { return }
        slots.swapAt(from, to)
        if offsets.indices.contains(from), offsets.indices.contains(to) { offsets.swapAt(from, to) }
        mediaChanged()
    }

    func swapSlots() {
        guard slots.count >= 2 else { return }
        slots.swapAt(0, 1)
        offsets.swapAt(0, 1)
        let a = style.text.labelA
        style.text.labelA = style.text.labelB
        style.text.labelB = a
        mediaChanged()
    }

    private func layoutChanged() {
        let filled = slots.compactMap { $0 }
        switch layout {
        case .single, .compare:
            // Keep the first two screens, filled ones first.
            slots = Array((filled + [nil, nil]).prefix(2))
            if layout == .single, slots[0] == nil { slots.swapAt(0, 1) }
        case .tour:
            slots = filled
        }
        offsets = slots.map { _ in 0 }
        selectedSlot = 0
        mediaChanged()
    }

    private func mediaChanged() {
        scheduleAutosave()
        if !hasVideo || tour { zooms = []; selectedZoomID = nil }
        rebuildComposition(resetTrim: true)
        scheduleRenderer()
        makeFilmstrip()
        refreshTemplatePreviews()
        refreshAutoZoom()
    }

    private func offsetsChanged() {
        scheduleAutosave()
        offsetsTask?.cancel()
        offsetsTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.rebuildComposition(resetTrim: true)
            self?.refreshAutoZoom()
        }
    }

    private func styleChanged(from old: StyleSettings) {
        scheduleAutosave()
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            if !Task.isCancelled, let self { self.style.save(for: self.platform) }
        }
        let is3D = style.device.style.is3D
        if old.canvas != style.canvas || old.export.fps != style.export.fps || old.export.includeAudio != style.export.includeAudio
            || old.device.style.is3D != is3D {
            rebuildComposition(resetTrim: false)
        }
        if old.canvas != style.canvas { refreshTemplatePreviews() }
        if old.speed != style.speed || old.speedUpPauses != style.speedUpPauses {
            timingChanged()
        } else if old.autoZoom != style.autoZoom || old.zoomRamp != style.zoomRamp {
            refreshAutoZoom()
        }
        if old != style { scheduleRenderer() }
    }

    // MARK: Preview pipeline

    private func previewJob() -> RenderJob {
        RenderJob(style: style, mode: layout, slots: activeSlots, offsets: activeOffsets, zooms: zooms,
                  trim: trimOut > trimIn ? trimIn...trimOut : nil, timeMaps: activeTimeMaps)
    }

    /// Rebuilds the renderer off the main thread. Rapid changes (slider drags) are coalesced.
    func scheduleRenderer() {
        rendererDirty = true
        guard !rendererBusy else { return }
        buildRenderer()
    }

    private func buildRenderer() {
        rendererDirty = false
        rendererBusy = true
        let params = previewJob().renderParams(canvasSize: style.canvas.size, zoomEnabled: selectedZoomID == nil, placeholders: true)
        let still = isStill
        Task.detached(priority: .userInitiated) { [weak self] in
            let renderer = SceneRenderer(params)
            let image = still ? renderer.makeCGImage() : nil
            await self?.install(renderer, still: image)
        }
    }

    private func install(_ renderer: SceneRenderer, still: CGImage?) {
        previewBox.renderer = renderer
        stillPreview = still
        if isMotion { playback.refresh() }
        rendererBusy = false
        if rendererDirty { buildRenderer() }
    }

    private func rebuildComposition(resetTrim: Bool) {
        compositionTask?.cancel()
        guard isMotion else {
            builtTimeMaps = []
            playback.load(nil)
            return
        }
        let job = previewJob()
        builtTimeMaps = job.timeMaps
        let tourPlan = job.tour
        let size = style.canvas.size
        // 3D frames are heavier to draw, so the live preview runs at 30 fps (exports use the full rate).
        let fps = style.device.style.is3D ? min(30, style.export.fps) : style.export.fps
        let audio = style.export.includeAudio
        compositionTask = Task { [weak self, previewBox] in
            do {
                let built = try await CompositionBuilder.build(slots: job.slots, offsets: job.offsets, starts: tourPlan?.videoStarts,
                                                               minDuration: tourPlan?.total ?? 0, timeMaps: job.timeMaps, includeAudio: audio,
                                                               renderSize: size, fps: fps, box: previewBox, tagging: .preview)
                guard !Task.isCancelled, let self else { return }
                self.playback.load(built)
                if let (a, b) = self.pendingTrim, b <= built.duration + 0.01, b > a {
                    self.trimIn = a
                    self.trimOut = min(b, built.duration)
                    self.pendingTrim = nil
                } else if resetTrim || self.trimOut <= 0 || self.trimOut > built.duration + 0.001 {
                    self.trimIn = 0
                    self.trimOut = built.duration
                }
                self.zooms = self.zooms.filter { $0.start < built.duration }.map { z in
                    var z = z
                    z.end = min(z.end, built.duration)
                    return z
                }
                if self.tour && !self.playback.isPlaying { self.playback.play() }
            } catch {
                self?.show(error)
            }
        }
    }

    private func updateLoop() {
        playback.loopRange = trimOut > trimIn ? trimIn...trimOut : nil
    }

    private func makeFilmstrip() {
        guard let item = activeSlots.compactMap({ $0 }).first(where: \.isVideo) else {
            filmstrip = activeSlots.compactMap { $0?.thumbnail }
            return
        }
        let url = item.url
        let duration = item.duration
        Task { [weak self] in
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 90, height: 90)
            var images: [NSImage] = []
            let count = 14
            for i in 0..<count {
                let t = duration * (Double(i) + 0.5) / Double(count)
                if let (cg, _) = try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)) {
                    images.append(NSImage(cgImage: cg, size: CGSize(width: cg.width, height: cg.height)))
                }
            }
            self?.filmstrip = images
        }
    }

    // MARK: Templates

    func applyTemplate(_ template: StyleTemplate) {
        style.applyLook(template.style)
        activeTemplateName = template.name
    }

    func saveTemplate(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        templates.removeAll { $0.name == trimmed }
        templates.append(StyleTemplate(name: trimmed, style: style))
        StyleTemplate.saveAll(templates)
        activeTemplateName = trimmed
        refreshTemplatePreviews()
        show("Saved template “\(trimmed)”")
    }

    func deleteTemplate(_ template: StyleTemplate) {
        templates.removeAll { $0.id == template.id }
        StyleTemplate.saveAll(templates)
    }

    /// Renders every template with your own screens, so you can pick by eye.
    func refreshTemplatePreviews() {
        previewsTask?.cancel()
        let base = style
        let mode = layout
        let items = activeSlots
        let all = allTemplates
        let previewSlots: [MediaItem?] = items.isEmpty ? [nil] : items
        let stills: [CIImage?] = previewSlots.map { item in
            if let still = item?.still { return still }
            if let thumb = item?.thumbnail, let cg = thumb.cgImage(forProposedRect: nil, context: nil, hints: nil) { return CIImage(cgImage: cg) }
            return nil
        }
        let aspects: [CGFloat] = previewSlots.map { $0?.aspect ?? 9.0 / 20.0 }
        previewsTask = Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            for template in all {
                if Task.isCancelled { return }
                var style = base
                style.applyLook(template.style)
                style.text.title = ""
                style.text.subtitle = ""
                let canvas = base.canvas.size
                let scale = 300 / canvas.width
                let params = RenderParams(canvasSize: CGSize(width: canvas.width * scale, height: canvas.height * scale), style: style,
                                          mode: mode, aspects: aspects, stills: stills, placeholders: [],
                                          zooms: [], zoomEnabled: false, tour: nil)
                let renderer = SceneRenderer(params)
                let image = renderer.makeCGImage(time: 1.5, frames: stills)
                await MainActor.run { [weak self] in
                    if let image { self?.templatePreviews[template.name] = image }
                }
            }
        }
    }

    // MARK: Motion analysis (auto-zoom + sped-up pauses)

    /// Analyses any recordings that haven't been analysed yet, then updates the automatic zooms and speed map.
    func refreshAutoZoom() {
        autoZoomTask?.cancel()
        let videos = activeSlots.compactMap { $0 }.filter(\.isVideo)
        let needsAnalysis = !tour && (style.autoZoom != .off || style.speedUpPauses) || (tour && style.speedUpPauses)
        let missing = needsAnalysis ? videos.filter { motionCache[$0.url] == nil } : []
        analyzingZoom = !missing.isEmpty
        autoZoomTask = Task { [weak self] in
            let phone = self?.platform == .android
            for item in missing {
                guard var events = try? await AutoZoom.detectEvents(url: item.url, offset: 0, phone: phone), !Task.isCancelled else { continue }
                if !item.clicks.isEmpty {
                    // Recorded clicks are exact: use them for zooms, and motion only for pauses and page changes.
                    events = events.filter(\.isGlobal) + item.clicks.map {
                        AutoZoom.Event(time: $0.t, u: $0.u, v: $0.v, area: 0.003, weight: 1000)
                    }
                    events.sort { $0.time < $1.time }
                }
                self?.motionCache[item.url] = events
            }
            guard !Task.isCancelled, let self else { return }
            self.analyzingZoom = false
            self.applyAnalysis()
        }
    }

    /// Rebuilds automatic zooms (in output time) and, if the speed map changed, the timeline.
    private func applyAnalysis() {
        let maps = activeTimeMaps
        if maps != builtTimeMaps { timingChanged(rescale: false) }

        let manual = zooms.filter { !$0.isAuto }
        guard !tour, style.autoZoom != .off, let index = activeSlots.firstIndex(where: { $0?.isVideo == true }),
              let item = activeSlots[index], let events = motionCache[item.url] else {
            if zooms.contains(where: \.isAuto) { zooms = manual }
            return
        }
        let offset = index < activeOffsets.count ? activeOffsets[index] : 0
        let map = index < maps.count ? maps[index] : nil
        let crop = Double(item.cropTop)
        // Clip time → output time; full-frame position → position on the visible (trimmed) content.
        let mapped = events.compactMap { e -> AutoZoom.Event? in
            guard e.time >= offset else { return nil }
            let v = (e.v - crop) / max(0.01, 1 - crop)
            guard e.isGlobal || v >= 0 else { return nil }
            let t = map?.output(at: e.time - offset) ?? (e.time - offset)
            return AutoZoom.Event(time: t, u: e.u, v: min(1, max(0, v)), area: e.area, weight: e.weight, isGlobal: e.isGlobal)
        }
        let length = map?.duration ?? (item.duration - offset)
        let auto = AutoZoom.segments(from: mapped, level: style.autoZoom, slot: index, ramp: style.zoomRamp, duration: length)
            .filter { a in !manual.contains { a.start < $0.end && a.end > $0.start } }
        zooms = (manual + auto).sorted { $0.start < $1.start }
    }

    /// Speed or sped-up pauses changed: keep manual zooms on the same moments, then rebuild.
    private func timingChanged(rescale: Bool = true) {
        let old = builtTimeMaps
        let new = activeTimeMaps
        func convert(_ t: Double, slot: Int) -> Double {
            let before = slot < old.count ? old[slot] : nil
            let after = slot < new.count ? new[slot] : nil
            let clip = before?.source(at: t) ?? t
            return after?.output(at: clip) ?? clip
        }
        let manual = zooms.filter { !$0.isAuto }
        if !manual.isEmpty {
            zooms = zooms.map { z in
                guard !z.isAuto else { return z }
                var z = z
                let slot = z.anchorSlot ?? 0
                z.start = convert(z.start, slot: slot)
                z.end = max(z.start + 0.4, convert(z.end, slot: slot))
                return z
            }
        }
        rebuildComposition(resetTrim: true)
        if rescale { refreshAutoZoom() }
    }

    // MARK: Browser bar trimming (web)

    func setCrop(_ value: CGFloat, slot: Int) {
        guard slot < slots.count, slots[slot] != nil else { return }
        slots[slot]?.cropTop = max(0, min(0.4, value))
        scheduleAutosave()
        cropTask?.cancel()
        cropTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self else { return }
            self.scheduleRenderer()
            self.refreshTemplatePreviews()
            self.applyAnalysis()
        }
    }

    /// Finds the browser's own toolbar in the recording and trims it off.
    func detectBrowserBar(slot: Int) {
        guard slot < slots.count, let item = slots[slot] else { return }
        Task {
            var image: CGImage?
            if let still = item.still {
                image = RenderCore.context.createCGImage(still, from: still.extent)
            } else {
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: item.url))
                generator.appliesPreferredTrackTransform = true
                image = try? await generator.image(at: CMTime(seconds: min(0.3, item.duration / 2), preferredTimescale: 600)).image
            }
            if let image, let crop = BrowserBar.detect(in: image, bundleID: item.sourceApp) {
                setCrop(crop, slot: slot)
                show("Trimmed the browser's toolbar. Fine-tune it with the slider if needed.")
            } else {
                show("Couldn't find a browser toolbar in this recording.", error: true)
            }
        }
    }

    // MARK: Zooms

    func addZoom(at time: Double? = nil) {
        let duration = playback.duration
        guard hasVideo, !tour, duration > 0.5 else { return }
        let length = min(2.5, duration)
        var start = max(0, min(time ?? playback.currentTime, duration - length))
        // Avoid stacking on top of an existing zoom.
        if let clash = zooms.first(where: { start < $0.end && start + length > $0.start }) {
            start = min(clash.end + 0.05, max(0, duration - length))
        }
        var focus = CGPoint(x: 0.5, y: 0.4)
        if let layout = currentLayout, let first = layout.devices.first {
            focus = CGPoint(x: first.screen.midX / layout.canvas.width, y: (first.screen.minY + first.screen.height * 0.35) / layout.canvas.height)
        }
        let zoom = ZoomSegment(start: start, end: min(duration, start + length), scale: max(1.5, style.autoZoom.scale),
                               focusX: focus.x, focusY: focus.y)
        zooms.append(zoom)
        zooms.sort { $0.start < $1.start }
        selectedZoomID = zoom.id
        playback.seek(to: zoom.start + min(style.zoomRamp, zoom.duration / 2) + 0.05)
    }

    func updateZoom(_ id: UUID, _ change: (inout ZoomSegment) -> Void) {
        guard let index = zooms.firstIndex(where: { $0.id == id }) else { return }
        var zoom = zooms[index]
        let before = zoom
        change(&zoom)
        // Once you aim a zoom by hand it stops following the automatic anchor.
        if zoom.focusX != before.focusX || zoom.focusY != before.focusY { zoom.anchorSlot = nil }
        if zoom != before { zoom.isAuto = false }
        zoom.scale = min(4, max(1.1, zoom.scale))
        zoom.focusX = min(1, max(0, zoom.focusX))
        zoom.focusY = min(1, max(0, zoom.focusY))
        zooms[index] = zoom
    }

    func deleteZoom(_ id: UUID) {
        zooms.removeAll { $0.id == id }
        if selectedZoomID == id { selectedZoomID = nil }
    }

    // MARK: Capture

    func captureScreenshot() {
        Task {
            do {
                let url = try await device.screenshot()
                await importMedia(url, into: tour ? slots.count : selectedSlot)
            } catch {
                show(error)
            }
        }
    }

    func captureLightDarkScreenshots() {
        Task {
            do {
                let (light, dark) = try await device.lightDarkScreenshots()
                enter(.compare)
                await importMedia(light, into: 0)
                await importMedia(dark, into: 1)
                style.text.labelA = "Light"
                style.text.labelB = "Dark"
                style.text.showLabels = true
                show("Captured light + dark. Your phone's theme was restored.")
            } catch {
                show(error)
            }
        }
    }

    func toggleRecording() {
        if device.isRecording {
            device.stopRecording()
            return
        }
        let target = tour ? slots.count : selectedSlot
        do {
            try device.startRecording { [weak self] result in
                self?.recordingPill.hide()
                self?.recordingFinished(result, slot: target)
            }
            recordingPill.show(title: device.device?.displayName ?? "Phone", startedAt: Date()) { [weak self] in
                self?.device.stopRecording()
            }
            show(device.options.showMirror ? "Recording. Use your phone or the mirror window, then press Stop." : "Recording. Use your phone, then press Stop.")
        } catch {
            show(error)
        }
    }

    private func recordingFinished(_ result: Result<URL, Error>, slot: Int) {
        switch result {
        case .success(let url):
            Task {
                await importMedia(url, into: slot)
                await finishAutomation()
            }
        case .failure(let error):
            show(error)
        }
    }

    /// Instant mode: once auto-zoom has run, export straight away.
    private func finishAutomation() async {
        guard device.options.autoExport, hasContent else { return }
        await autoZoomTask?.value
        export()
    }

    /// Records a light-mode take, flips the phone to dark mode, then records the dark take.
    func recordLightDarkPair() {
        guard !device.isRecording else { return }
        Task {
            do {
                pairOriginalMode = try await device.setDarkMode(false)
                try await Task.sleep(for: .seconds(1.5))
                enter(.compare)
                pairStage = .light
                try device.startRecording { [weak self] result in self?.pairTakeFinished(result) }
                show("Take 1 of 2: LIGHT mode. Do your demo, then press Stop.")
            } catch {
                pairStage = nil
                show(error)
            }
        }
    }

    func cancelPair() {
        pairStage = nil
        Task { await device.restoreNightMode(pairOriginalMode) }
    }

    private func pairTakeFinished(_ result: Result<URL, Error>) {
        guard let stage = pairStage else { return }
        guard case .success(let url) = result else {
            if case .failure(let error) = result { show(error) }
            cancelPair()
            return
        }
        Task {
            switch stage {
            case .light:
                await importMedia(url, into: 0)
                do {
                    try await device.setDarkMode(true)
                    try await Task.sleep(for: .seconds(1.8))
                    pairStage = .dark
                    try device.startRecording { [weak self] result in self?.pairTakeFinished(result) }
                    show("Take 2 of 2: DARK mode. Repeat the same steps, then press Stop.")
                } catch {
                    show(error)
                    cancelPair()
                }
            case .dark:
                await importMedia(url, into: 1)
                style.text.labelA = "Light"
                style.text.labelB = "Dark"
                style.text.showLabels = true
                pairStage = nil
                await device.restoreNightMode(pairOriginalMode)
                show("Both takes are in. Use “Line up the takes” if they're out of sync.")
                await finishAutomation()
            }
        }
    }

    func setCleanStatusBar(_ on: Bool) {
        Task {
            do {
                try await device.setCleanStatusBar(on)
                show(on ? "Status bar cleaned up: 9:41, full battery and signal, no notifications." : "Status bar back to normal.")
            } catch {
                show(error)
            }
        }
    }

    func setPhoneDarkMode(_ dark: Bool) {
        Task {
            do { try await device.setDarkMode(dark) } catch { show(error) }
        }
    }

    // MARK: Mac window capture (web)

    func refreshMacWindows() {
        Task {
            do { try await macCapture.refreshWindows() } catch { show(error) }
        }
    }

    func captureWindowScreenshot() {
        Task {
            do {
                let url = try await macCapture.screenshot()
                await importMedia(url, into: tour ? slots.count : selectedSlot)
            } catch {
                show(error)
            }
        }
    }

    func toggleWindowRecording() {
        if macCapture.isRecording {
            macCapture.stopRecording()
            return
        }
        let target = tour ? slots.count : selectedSlot
        Task {
            do {
                try await macCapture.startRecording { [weak self] result in
                    self?.recordingPill.hide()
                    self?.recordingFinished(result, slot: target)
                }
                recordingPill.show(title: macCapture.selectedWindow?.appName ?? "Window", startedAt: Date()) { [weak self] in
                    self?.macCapture.stopRecording()
                }
                show("Recording \(macCapture.selectedWindow?.label ?? "the window"). Your clicks are tracked for auto-zoom. Press Stop when done.")
            } catch {
                show(error)
            }
        }
    }

    /// Record button for whichever platform is active.
    func toggleAnyRecording() {
        isWeb ? toggleWindowRecording() : toggleRecording()
    }

    func captureAnyScreenshot() {
        isWeb ? captureWindowScreenshot() : captureScreenshot()
    }

    // MARK: Phone gallery

    func openPhoneGallery() {
        showPhoneGallery = true
        loadPhoneGallery()
    }

    func loadPhoneGallery() {
        loadingGallery = true
        Task {
            defer { loadingGallery = false }
            do {
                phoneGallery = try await device.recentMedia()
            } catch {
                phoneGallery = []
                show(error)
            }
        }
    }

    func importFromPhone(_ media: RemoteMedia, slot: Int) {
        Task {
            do {
                let url = try await device.pull(media)
                await importMedia(url, into: slot)
            } catch {
                show(error)
            }
        }
    }

    func grabLatestFromPhone() {
        Task {
            do {
                guard let latest = try await device.recentMedia().first else { throw CaptureError.nothingOnPhone }
                let url = try await device.pull(latest)
                await importMedia(url, into: tour ? slots.count : selectedSlot)
                show("Imported \(latest.name)")
            } catch {
                show(error)
            }
        }
    }

    // MARK: Export

    private func exportBaseName() -> String {
        let name = style.text.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let safe = name.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>")).joined().prefix(40)
        return safe.isEmpty ? "AppX Motion \(Paths.timestamp())" : "\(safe) \(Paths.timestamp())"
    }

    func export() {
        guard hasContent, !isExporting else {
            if !hasContent { show(ExportError.nothingToExport) }
            return
        }
        playback.pause()
        selectedZoomID = nil
        let job = previewJob()
        let still = isStill
        let base = Paths.exports.appendingPathComponent(exportBaseName())
        let token = CancelToken()
        exportToken = token
        exportPhase = .running(0)
        showExportSheet = true

        Task {
            do {
                let url: URL
                if still {
                    url = Paths.unique(base.appendingPathExtension(style.export.imageFormat.ext))
                    try await Task.detached(priority: .userInitiated) { try ExportEngine.exportStill(job: job, to: url) }.value
                } else {
                    url = Paths.unique(base.appendingPathExtension("mp4"))
                    try await ExportEngine.exportVideo(job: job, to: url, cancel: token) { [weak self] p in
                        Task { @MainActor in
                            if case .running = self?.exportPhase { self?.exportPhase = .running(p) }
                        }
                    }
                }
                await finishExport(url, isVideo: !still)
            } catch {
                exportPhase = .idle
                showExportSheet = false
                show(error)
            }
        }
    }

    func exportCurrentFrame() {
        guard isMotion, !isExporting else { return export() }
        playback.pause()
        let job = previewJob()
        let time = playback.currentTime
        let url = Paths.unique(Paths.exports.appendingPathComponent(exportBaseName() + " frame").appendingPathExtension(style.export.imageFormat.ext))
        exportPhase = .running(0.5)
        showExportSheet = true
        Task {
            do {
                try await ExportEngine.exportFrame(job: job, time: time, to: url)
                await finishExport(url, isVideo: false)
            } catch {
                exportPhase = .idle
                showExportSheet = false
                show(error)
            }
        }
    }

    func cancelExport() {
        exportToken?.cancel()
    }

    private func finishExport(_ url: URL, isVideo: Bool) async {
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        var thumbnail: NSImage?
        var size = style.canvas.size
        var duration: Double?
        if isVideo {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.maximumSize = CGSize(width: 900, height: 900)
            let length = (try? await asset.load(.duration).seconds) ?? 0
            if let (cg, _) = try? await generator.image(at: CMTime(seconds: length * 0.4, preferredTimescale: 600)) {
                thumbnail = NSImage(cgImage: cg, size: CGSize(width: cg.width, height: cg.height))
            }
            duration = length
        } else if let image = NSImage(contentsOf: url) {
            thumbnail = image
            if let rep = image.representations.first { size = CGSize(width: rep.pixelsWide, height: rep.pixelsHigh) }
        }
        lastExport = ExportResult(url: url, thumbnail: thumbnail, isVideo: isVideo, bytes: bytes, pixelSize: size, duration: duration)
        exportPhase = .done
        if device.options.copyAfterExport { copyExportToClipboard(quiet: true) }
    }

    func copyExportToClipboard(quiet: Bool = false) {
        guard let result = lastExport else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(result.url.absoluteString, forType: .fileURL)
        if !result.isVideo, let data = try? Data(contentsOf: result.url) {
            item.setData(data, forType: result.url.pathExtension.lowercased() == "png" ? .png : NSPasteboard.PasteboardType("public.jpeg"))
        }
        pasteboard.writeObjects([item])
        if !quiet {
            show(result.isVideo ? "Copied. Paste into the X composer, or drag the preview in." : "Image copied. Paste it straight into X.")
        }
    }

    func revealExport() {
        guard let result = lastExport else { return }
        NSWorkspace.shared.activateFileViewerSelecting([result.url])
    }

    func openXComposer() {
        if let url = URL(string: "https://x.com/compose/post") { NSWorkspace.shared.open(url) }
    }

    func openExportsFolder() {
        NSWorkspace.shared.open(Paths.exports)
    }

    func openCapturesFolder() {
        NSWorkspace.shared.open(Paths.captures)
    }

    // MARK: Keyboard

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.handleKey(event) else { return event }
                return nil
            }
        }
    }

    /// Space play/pause · ←/→ step · Z add zoom · ⌫ delete zoom · Esc deselect · I/O set trim.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard let window = NSApp.keyWindow, window.sheetParent == nil, !(window is NSPanel) else { return false }
        if window.firstResponder is NSText { return false }
        let mods = event.modifierFlags.intersection([.command, .option, .control])
        guard mods.isEmpty else { return false }
        let shift = event.modifierFlags.contains(.shift)

        switch event.keyCode {
        case 49: // space
            guard isMotion else { return false }
            playback.toggle()
            return true
        case 123, 124: // ← →
            guard isMotion else { return false }
            let step = shift ? 1.0 : 1.0 / Double(style.export.fps)
            playback.step(by: event.keyCode == 123 ? -step : step)
            return true
        case 51, 117: // delete
            guard let id = selectedZoomID else { return false }
            deleteZoom(id)
            return true
        case 53: // esc
            guard selectedZoomID != nil else { return false }
            selectedZoomID = nil
            return true
        default:
            break
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "z" where hasVideo && !tour:
            addZoom()
            return true
        case "i" where isMotion:
            trimIn = min(playback.currentTime, trimOut - 0.2)
            return true
        case "o" where isMotion:
            trimOut = max(playback.currentTime, trimIn + 0.2)
            return true
        default:
            return false
        }
    }
}
