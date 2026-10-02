import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PlatformSwitch()
                if model.isWeb {
                    WebCaptureSection()
                } else {
                    PhoneSection()
                }
                Divider().padding(.horizontal, 16)
                SlotsSection()
            }
            .padding(.vertical, 4)
        }
        .scrollIndicators(.never)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - Platform

private struct PlatformSwitch: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Platform.allCases) { platform in
                let selected = model.platform == platform
                Button {
                    model.switchPlatform(to: platform)
                } label: {
                    Label(platform.label, systemImage: platform.icon)
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(selected ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .foregroundStyle(selected ? Color.white : Color.primary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .disabled(model.isRecordingAnything || model.isExporting)
        .help("Android and web each keep their own media, look and templates")
    }
}

// MARK: - Web capture (Mac windows)

private struct WebCaptureSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var capture = model.macCapture
        @Bindable var device = model.device
        InspectorSection(title: "Capture a window", systemImage: "macwindow") {
            HStack(spacing: 6) {
                Picker("Window", selection: $capture.selectedWindowID) {
                    if capture.windows.isEmpty { Text("No windows found").tag(CGWindowID?.none) }
                    ForEach(capture.windows) { window in
                        Text(window.label).tag(Optional(window.id))
                    }
                }
                .labelsHidden()
                .truncationMode(.middle)
                Button { model.refreshMacWindows() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Refresh the window list")
            }

            if capture.isRecording {
                Button {
                    model.toggleWindowRecording()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "stop.fill").font(.system(size: 13, weight: .bold))
                        Text("Stop recording").font(.system(size: 13, weight: .semibold))
                        Spacer()
                        if let start = capture.recordingStartedAt {
                            SwiftUI.TimelineView(.periodic(from: start, by: 0.5)) { context in
                                Text(formatTime(context.date.timeIntervalSince(start)).dropLast(3)).monospacedDigit()
                                    .font(.system(size: 13, weight: .semibold))
                            }
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.red, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
            } else {
                VStack(spacing: 6) {
                    ActionTile(title: "Record window", systemImage: "record.circle", tint: .red, subtitle: "Your clicks drive the auto-zoom") {
                        model.toggleWindowRecording()
                    }
                    ActionTile(title: "Screenshot window", systemImage: "camera.viewfinder", tint: .blue, subtitle: "Just the window, no desktop") {
                        model.captureWindowScreenshot()
                    }
                }
                .disabled(capture.selectedWindowID == nil || capture.busyMessage != nil)
            }

            VStack(alignment: .leading, spacing: 7) {
                Toggle(isOn: $device.options.autoExport) {
                    HStack(spacing: 4) {
                        Image(systemName: "bolt.fill").foregroundStyle(.yellow)
                        Text("Instant: export when I stop").fontWeight(.semibold)
                    }
                }
                Toggle("Copy the export to the clipboard", isOn: $device.options.copyAfterExport)
                Toggle("Show the mouse pointer", isOn: $capture.options.showCursor)
                Toggle("Trim the browser's own toolbar", isOn: $capture.options.hideBrowserBar)
                    .help("Removes the real tabs and address bar so the clean Browser frame can replace them")
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .font(.system(size: 11.5))

            Text("Tip: size the browser window the way you want it to look (around 1440×900 works well) before you record.")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }
        .onAppear { if capture.windows.isEmpty { model.refreshMacWindows() } }
    }
}

// MARK: - Phone capture

private struct PhoneSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var device = model.device
        InspectorSection(title: "Phone", systemImage: "iphone.gen3") {
            DeviceStatusRow()

            if device.isRecording {
                RecordingRow()
            } else if let busy = device.busyMessage {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(busy).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            }

            VStack(spacing: 6) {
                if !device.isRecording {
                    ActionTile(title: "Record screen", systemImage: "record.circle", tint: .red,
                               subtitle: device.options.showMirror ? "Mirrors your phone on the Mac" : "Records while you use the phone") {
                        model.toggleRecording()
                    }
                }
                ActionTile(title: "Screenshot", systemImage: "camera.viewfinder", tint: .blue, subtitle: "Grab the phone screen now") {
                    model.captureScreenshot()
                }
                LightDarkRow()
                ActionTile(title: "From phone gallery", systemImage: "photo.on.rectangle.angled", tint: .teal,
                           subtitle: "Recordings you made on the phone") {
                    model.openPhoneGallery()
                }
            }
            .disabled(model.device.device == nil || model.device.busyMessage != nil)

            if model.pairStage != nil {
                HStack {
                    Image(systemName: "circle.lefthalf.filled")
                    Text(model.pairStage == .light ? "Light take: press Stop when done" : "Dark take: repeat the same steps")
                        .font(.system(size: 11.5, weight: .medium))
                    Spacer()
                    Button("Cancel") { model.cancelPair() }.controlSize(.small)
                }
                .padding(8)
                .background(Color.purple.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }

            CaptureOptionsView()
        }
    }
}

/// One row, two actions: light/dark screenshot pair or a guided two-take recording.
private struct LightDarkRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "circle.lefthalf.filled")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.purple)
                .frame(width: 28, height: 28)
                .background(Color.purple.opacity(0.14), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text("Light + Dark").font(.system(size: 12.5, weight: .semibold))
                Text("Flips the phone's theme for you").font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            VStack(spacing: 4) {
                Button("Photos") { model.captureLightDarkScreenshots() }
                    .help("Screenshot in light mode, then dark mode, then restore your theme")
                Button("Video") { model.recordLightDarkPair() }
                    .help("Record a light take, flip to dark mode, record the dark take")
            }
            .controlSize(.mini)
            .frame(width: 58)
        }
        .padding(7)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.045)))
    }
}

private struct DeviceStatusRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var device = model.device
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .shadow(color: statusColor.opacity(0.6), radius: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                Text(detail).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
            if device.devices.filter(\.isReady).count > 1 {
                Picker("", selection: $device.selectedSerial) {
                    ForEach(device.devices.filter(\.isReady)) { d in
                        Text(d.displayName).tag(Optional(d.serial))
                    }
                }
                .labelsHidden()
                .frame(width: 90)
            }
        }
        .padding(9)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var statusColor: Color {
        if model.device.adbPath == nil { return .red }
        if model.device.device != nil { return .green }
        if model.device.unauthorizedDevice != nil { return .orange }
        return .gray
    }

    private var title: String {
        if model.device.adbPath == nil { return "adb not found" }
        if let d = model.device.device { return d.displayName }
        if model.device.unauthorizedDevice != nil { return "Waiting for permission" }
        return "No phone connected"
    }

    private var detail: String {
        if model.device.adbPath == nil { return "brew install android-platform-tools" }
        if let d = model.device.device { return d.isWireless ? "Connected over Wi-Fi" : "Connected over USB" }
        if model.device.unauthorizedDevice != nil { return "Tap “Allow USB debugging” on the phone" }
        return "Plug in over USB with USB debugging on, or drop files below"
    }
}

private struct RecordingRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            model.toggleRecording()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "stop.fill").font(.system(size: 13, weight: .bold))
                Text("Stop recording").font(.system(size: 13, weight: .semibold))
                Spacer()
                if let start = model.device.recordingStartedAt {
                    SwiftUI.TimelineView(.periodic(from: start, by: 0.5)) { context in
                        Text(formatTime(context.date.timeIntervalSince(start)).dropLast(3))
                            .monospacedDigit()
                            .font(.system(size: 13, weight: .semibold))
                    }
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.red, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.escape, modifiers: [])
    }
}

private struct CaptureOptionsView: View {
    @Environment(AppModel.self) private var model
    @State private var darkMode: Bool?

    var body: some View {
        @Bindable var device = model.device
        VStack(alignment: .leading, spacing: 7) {
            Toggle(isOn: $device.options.autoExport) {
                HStack(spacing: 4) {
                    Image(systemName: "bolt.fill").foregroundStyle(.yellow)
                    Text("Instant: export when I stop").fontWeight(.semibold)
                }
            }
            .help("When a recording stops, AppX Motion applies your template and auto-zoom, exports for X and copies the file")
            Toggle("Copy the export to the clipboard", isOn: $device.options.copyAfterExport)
            Toggle("Mirror window while recording", isOn: $device.options.showMirror)
            Toggle("Show taps on screen", isOn: $device.options.showTouches)
            Toggle("Record phone audio", isOn: $device.options.recordAudio)
            Toggle("Clean status bar (9:41)", isOn: Binding(
                get: { model.style.cleanStatusBar },
                set: { model.style.cleanStatusBar = $0 }
            ))
            .help("Replaces the status bar in your videos and screenshots with a clean one: 9:41, full battery and signal, no notifications. Works with any phone, including Samsung.")
            HStack {
                Text("Phone theme")
                Spacer()
                Button("Light") { model.setPhoneDarkMode(false) }
                Button("Dark") { model.setPhoneDarkMode(true) }
            }
            .controlSize(.small)
            .disabled(model.device.device == nil)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .font(.system(size: 11.5))
        .padding(.top, 2)
    }
}

// MARK: - Slots

private struct SlotsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        InspectorSection(title: title, systemImage: "square.stack") {
            if model.tour {
                ForEach(Array(model.slots.indices), id: \.self) { index in
                    SlotCard(index: index)
                }
                Text("Screens appear in this order. Capture, drop or import more to add them.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            } else {
                SlotCard(index: 0)
                if model.compare {
                    HStack {
                        Spacer()
                        Button {
                            model.swapSlots()
                        } label: {
                            Label("Swap", systemImage: "arrow.up.arrow.down")
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderless)
                        Spacer()
                    }
                    SlotCard(index: 1)
                }
            }
            Button {
                model.showImporter = true
            } label: {
                Label(model.tour ? "Add screens…" : "Import files…", systemImage: "folder")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.regular)
            if !model.tour {
                Text("Tip: drop 2 files to compare them, or 3+ for a camera tour.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var title: String {
        switch model.layout {
        case .single: "Media"
        case .compare: "Phones"
        case .tour: "Screens (\(model.slots.count))"
        }
    }
}

private struct SlotCard: View {
    @Environment(AppModel.self) private var model
    let index: Int
    @State private var targeted = false

    var body: some View {
        let item = index < model.slots.count ? model.slots[index] : nil
        let selected = model.selectedSlot == index
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.07))
                if let thumb = item?.thumbnail {
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                } else {
                    Image(systemName: "plus").foregroundStyle(.secondary)
                }
                if item?.isVideo == true {
                    Image(systemName: "play.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(.black.opacity(0.5), in: Circle())
                }
            }
            .frame(width: 40, height: 72)
            .clipped()

            VStack(alignment: .leading, spacing: 3) {
                Text(model.tour ? "Screen \(index + 1)" : model.compare ? (index == 0 ? "Left phone" : "Right phone") : "Recording")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(selected && model.compare ? Color.accentColor : .secondary)
                Text(item?.name ?? "Empty: capture, drop or import")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2)
                    .truncationMode(.middle)
                if let item {
                    Text(item.summary).font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if model.tour {
                VStack(spacing: 2) {
                    Button { model.moveSlot(index, by: -1) } label: { Image(systemName: "chevron.up") }
                        .disabled(index == 0)
                    Button { model.moveSlot(index, by: 1) } label: { Image(systemName: "chevron.down") }
                        .disabled(index >= model.slots.count - 1)
                }
                .buttonStyle(.borderless)
                .controlSize(.mini)
            }
            if item != nil {
                Button {
                    model.clearSlot(index)
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove")
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(targeted ? 0.12 : 0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(selected && model.compare ? 0.9 : 0), lineWidth: 1.5)
        )
        .contentShape(Rectangle())
        .onTapGesture { model.selectedSlot = index }
        .help(model.compare ? "Click to make this phone the capture target" : "")
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            loadFileURLs(providers) { urls in
                guard let url = urls.first else { return }
                Task { await model.importMedia(url, into: index) }
            }
            return true
        }
    }
}

/// Resolves dropped file URLs.
func loadFileURLs(_ providers: [NSItemProvider], completion: @escaping @MainActor ([URL]) -> Void) {
    let group = DispatchGroup()
    let lock = NSLock()
    var urls: [(Int, URL)] = []
    for (i, provider) in providers.enumerated() where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
        group.enter()
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            if let url {
                lock.lock(); urls.append((i, url)); lock.unlock()
            }
            group.leave()
        }
    }
    group.notify(queue: .main) {
        let sorted = urls.sorted { $0.0 < $1.0 }.map(\.1)
        MainActor.assumeIsolated { completion(sorted) }
    }
}
