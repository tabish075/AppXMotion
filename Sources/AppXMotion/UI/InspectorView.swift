import SwiftUI

struct InspectorView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("PostFrame.showMoreOptions") private var showMore = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                TemplatesSection()
                Divider().padding(.horizontal, 16)
                QuickSection()
                Divider().padding(.horizontal, 16)
                ExportSettingsSection()
                Divider().padding(.horizontal, 16)

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showMore.toggle() }
                } label: {
                    HStack {
                        Image(systemName: "slider.horizontal.3")
                        Text("More options").font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .rotationEffect(.degrees(showMore ? 90 : 0))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if showMore {
                    BackgroundSection()
                    Divider().padding(.horizontal, 16)
                    DeviceSection()
                    Divider().padding(.horizontal, 16)
                    TextSection()
                    if model.hasVideo && !model.tour {
                        Divider().padding(.horizontal, 16)
                        ZoomSection()
                        if model.compare {
                            Divider().padding(.horizontal, 16)
                            ClipsSection()
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .scrollIndicators(.never)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - Templates

private struct TemplatesSection: View {
    @Environment(AppModel.self) private var model
    @State private var naming = false
    @State private var newName = ""

    var body: some View {
        InspectorSection(title: "Templates", systemImage: "wand.and.stars", trailing: AnyView(
            Button { naming = true } label: { Image(systemName: "plus") }
                .buttonStyle(.borderless)
                .help("Save the current look as a template")
        )) {
            let canvas = model.style.canvas.size
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 12) {
                ForEach(model.allTemplates) { template in
                    let selected = model.activeTemplateName == template.name
                    Button {
                        model.applyTemplate(template)
                    } label: {
                        VStack(spacing: 5) {
                            Group {
                                if let preview = model.templatePreviews[template.name] {
                                    Image(decorative: preview, scale: 1)
                                        .resizable()
                                        .interpolation(.high)
                                } else {
                                    ZStack {
                                        BackgroundSwatch(settings: template.style.background, size: 60)
                                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                                        ProgressView().controlSize(.small)
                                    }
                                }
                            }
                            .aspectRatio(canvas.width / canvas.height, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(Color.accentColor, lineWidth: selected ? 2.5 : 0)
                                    .padding(-3)
                            )
                            Text(template.name)
                                .font(.system(size: 11, weight: selected ? .semibold : .medium))
                                .foregroundStyle(selected ? Color.accentColor : .primary)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if !template.builtIn {
                            Button("Delete template", role: .destructive) { model.deleteTemplate(template) }
                        }
                    }
                }
            }
        }
        .alert("Save template", isPresented: $naming) {
            TextField("Name, e.g. “My app launch”", text: $newName)
            Button("Save") {
                model.saveTemplate(named: newName)
                newName = ""
            }
            Button("Cancel", role: .cancel) { newName = "" }
        } message: {
            Text("Saves the background, phone, angle, shadow and zoom style so you can reuse them in one click.")
        }
    }
}

// MARK: - Quick tweaks

private struct QuickSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        InspectorSection(title: "Quick tweaks", systemImage: "dial.low") {
            // Background
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(BackgroundPreset.all) { preset in
                        BackgroundSwatch(settings: preset.settings, selected: model.style.background == preset.settings, size: 28)
                            .onTapGesture { model.style.background = preset.settings }
                            .help(preset.name)
                    }
                }
                .padding(4)
            }
            .scrollIndicators(.never)

            if !model.isWeb && model.hasContent {
                Toggle(isOn: $model.style.cleanStatusBar) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Clean status bar").font(.system(size: 12, weight: .medium))
                        Text("9:41, full battery, no notification icons").font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
            }

            if model.style.device.style == .browser {
                HStack(spacing: 8) {
                    TextField("Address bar text", text: $model.style.device.browserURL)
                        .textFieldStyle(.roundedBorder)
                    Picker("Theme", selection: $model.style.device.chromeTheme) {
                        Image(systemName: "sun.max").tag(ChromeTheme.light)
                        Image(systemName: "moon").tag(ChromeTheme.dark)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 80)
                }
            }

            if model.style.device.style == .macbook3D {
                HStack(spacing: 9) {
                    ForEach(LaptopFinish.all) { finish in
                        Circle()
                            .fill(LinearGradient(colors: [finish.body.mixed(with: .white, 0.35).color, finish.body.color],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
                            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: model.style.device.laptopFinishID == finish.id ? 2.5 : 0).padding(-3.5))
                            .frame(width: 22, height: 22)
                            .onTapGesture { model.style.device.laptopFinishID = finish.id }
                            .help(finish.name)
                    }
                }
                .padding(.vertical, 2)
                LabeledRow("Angle") {
                    Picker("Angle", selection: $model.style.device.pose) {
                        ForEach(DevicePose.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }

            if model.style.device.style == .galaxy3D {
                // Titanium finish
                HStack(spacing: 9) {
                    ForEach(PhoneFinish.all) { finish in
                        Circle()
                            .fill(LinearGradient(colors: [finish.frame.mixed(with: .white, 0.35).color, finish.frame.color],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
                            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: model.style.device.finishID == finish.id ? 2.5 : 0).padding(-3.5))
                            .frame(width: 22, height: 22)
                            .onTapGesture { model.style.device.finishID = finish.id }
                            .help(finish.name)
                    }
                }
                .padding(.vertical, 2)

                LabeledRow("Angle") {
                    Picker("Angle", selection: $model.style.device.pose) {
                        ForEach(DevicePose.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                SliderRow(title: "Corners (lower = squarer, less of your app is cut off)", value: $model.style.device.roundness, range: 0.3...1.6)
            }

            if model.hasVideo && !model.tour {
                LabeledRow("Auto-zoom") {
                    Picker("Auto-zoom", selection: $model.style.autoZoom) {
                        ForEach(AutoZoomLevel.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                HStack(spacing: 6) {
                    if model.analyzingZoom {
                        ProgressView().controlSize(.mini)
                        Text("Finding the moments to zoom into…")
                    } else {
                        let count = model.zooms.filter(\.isAuto).count
                        Image(systemName: "sparkles")
                        Text(model.style.autoZoom == .off ? "Automatic zooms are off."
                             : count == 0 ? "No obvious taps found. Add one with Z if you like."
                             : "\(count) automatic zoom\(count == 1 ? "" : "s") on taps and changes.")
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            if model.hasVideo {
                LabeledRow("Speed") {
                    Picker("Speed", selection: $model.style.speed) {
                        ForEach(StyleSettings.speedOptions, id: \.self) { Text(speedLabel($0)).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                if !model.compare {
                    Toggle(isOn: $model.style.speedUpPauses) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Speed up pauses").font(.system(size: 12, weight: .medium))
                            Text("Loading and waiting moments play 4× faster").font(.system(size: 10.5)).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                }
                if let summary = model.speedSummary, abs(summary.result - summary.original) > 0.05 {
                    Label("Plays in \(String(format: "%.1f", summary.result))s instead of \(String(format: "%.1f", summary.original))s",
                          systemImage: "hare")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            if model.tour {
                Label("The camera tours every screen automatically: overview, each screen, close-ups, back out.", systemImage: "camera.metering.matrix")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            TextField("Headline (optional)", text: $model.style.text.title, axis: .vertical)
                .lineLimit(1...3)
                .textFieldStyle(.roundedBorder)
        }
    }
}

func speedLabel(_ speed: Double) -> String {
    speed == 0.5 ? "½×" : speed == floor(speed) ? "\(Int(speed))×" : String(format: "%.1f×", speed)
}

private struct LabeledRow<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 12)).frame(width: 70, alignment: .leading)
            content
        }
    }
}

// MARK: - Background

private struct BackgroundSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        InspectorSection(title: "Background", systemImage: "paintpalette") {
            Picker("Style", selection: $model.style.background.style) {
                ForEach(BackgroundStyle.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if model.style.background.style != .blurredApp {
                HStack(spacing: 12) {
                    ColorPicker(model.style.background.style == .solid ? "Color" : "From", selection: colorBinding(\.background.color1), supportsOpacity: false)
                    if model.style.background.style != .solid {
                        ColorPicker("To", selection: colorBinding(\.background.color2), supportsOpacity: false)
                    }
                    Spacer()
                }
                .font(.system(size: 12))
            } else {
                Text("Uses a heavily blurred copy of your app's screen, so the background always matches the app.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if model.style.background.style == .gradient {
                SliderRow(title: "Angle", value: $model.style.background.angle, range: 0...360) { "\(Int($0))°" }
            }
        }
    }

    private func colorBinding(_ keyPath: WritableKeyPath<StyleSettings, RGBAColor>) -> Binding<Color> {
        Binding(
            get: { model.style[keyPath: keyPath].color },
            set: { model.style[keyPath: keyPath] = RGBAColor(NSColor($0)) }
        )
    }
}

// MARK: - Device

private struct DeviceSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        InspectorSection(title: "Device", systemImage: "iphone") {
            Picker("Frame", selection: $model.style.device.style) {
                ForEach(FrameStyle.styles(for: model.platform)) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if model.style.device.style == .phone || model.style.device.style == .minimal {
                HStack(spacing: 8) {
                    ForEach(FrameColor.all) { color in
                        Circle()
                            .fill(LinearGradient(colors: [color.highlight.color, color.body.color], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
                            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: model.style.device.frameColorID == color.id ? 2.5 : 0).padding(-3.5))
                            .frame(width: 22, height: 22)
                            .onTapGesture { model.style.device.frameColorID = color.id }
                            .help(color.name)
                    }
                }
                .padding(.vertical, 2)
            }

            if model.isWeb, model.slots.indices.contains(model.selectedSlot), let item = model.slots[model.selectedSlot] {
                VStack(alignment: .leading, spacing: 4) {
                    SliderRow(title: "Trim browser toolbar", value: Binding(
                        get: { Double(item.cropTop) },
                        set: { model.setCrop(CGFloat($0), slot: model.selectedSlot) }
                    ), range: 0...0.3)
                    Button("Detect automatically") { model.detectBrowserBar(slot: model.selectedSlot) }
                        .controlSize(.small)
                }
            }
            if model.isWeb && model.hasVideo {
                Toggle("Show click ripples", isOn: $model.style.device.showClicks)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
            }

            SliderRow(title: "Size", value: $model.style.device.size, range: 0.5...1.0)
            if model.style.device.style != .macbook3D {
                SliderRow(title: "Corner radius", value: $model.style.device.roundness,
                          range: model.style.device.style == .galaxy3D ? 0.3...1.6 : 0...1.8)
            }

            if model.style.device.style == .phone || model.style.device.style == .minimal {
                HStack {
                    Toggle("Camera hole", isOn: $model.style.device.showCamera)
                    if model.style.device.style == .phone {
                        Toggle("Side buttons", isOn: $model.style.device.showButtons)
                    }
                }
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
            }

            Toggle(isOn: $model.style.shadow.enabled) {
                Text("Drop shadow").font(.system(size: 12, weight: .medium))
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            if model.style.shadow.enabled {
                SliderRow(title: "Shadow strength", value: $model.style.shadow.strength, range: 0...1.5)
                SliderRow(title: "Shadow softness", value: $model.style.shadow.softness, range: 0...1)
            }
        }
    }
}

// MARK: - Text

private struct TextSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        InspectorSection(title: "Text", systemImage: "textformat") {
            TextField("Subtitle (optional)", text: $model.style.text.subtitle, axis: .vertical)
                .lineLimit(1...3)
                .textFieldStyle(.roundedBorder)

            if model.compare {
                Toggle("Labels under phones", isOn: $model.style.text.showLabels)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                if model.style.text.showLabels {
                    HStack {
                        TextField("Left", text: $model.style.text.labelA).textFieldStyle(.roundedBorder)
                        TextField("Right", text: $model.style.text.labelB).textFieldStyle(.roundedBorder)
                    }
                }
            }

            SliderRow(title: "Text size", value: $model.style.text.size, range: 0.6...1.6)

            HStack {
                Picker("Color", selection: $model.style.text.colorMode) {
                    Text("Auto").tag(TextColorMode.auto)
                    Text("Custom").tag(TextColorMode.custom)
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
                if model.style.text.colorMode == .custom {
                    ColorPicker("", selection: Binding(
                        get: { model.style.text.color.color },
                        set: { model.style.text.color = RGBAColor(NSColor($0)) }
                    ), supportsOpacity: false)
                    .labelsHidden()
                }
                Spacer()
            }
            .font(.system(size: 12))
        }
    }
}

// MARK: - Zoom

private struct ZoomSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        InspectorSection(title: "Zoom (manual)", systemImage: "plus.magnifyingglass") {
            if let zoom = model.selectedZoom {
                SliderRow(title: "Zoom level", value: Binding(
                    get: { zoom.scale },
                    set: { value in model.updateZoom(zoom.id) { $0.scale = value } }
                ), range: 1.1...3.5) { String(format: "%.1f×", $0) }

                HStack {
                    Text("\(formatTime(zoom.start)) → \(formatTime(zoom.end))")
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(role: .destructive) {
                        model.deleteZoom(zoom.id)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .controlSize(.small)
                }
                Text("Drag on the preview to aim the zoom. Drag the purple block to move it, or its edges to change the length.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Button("Done") { model.selectedZoomID = nil }
                    .controlSize(.small)
            } else {
                Button {
                    model.addZoom()
                } label: {
                    Label("Add zoom at playhead", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                Text("Automatic zooms already cover taps and changes. Add your own with Z, or click one on the timeline to adjust it.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            SliderRow(title: "Ease in / out", value: $model.style.zoomRamp, range: 0.2...1.2) { String(format: "%.2fs", $0) }
        }
    }
}

// MARK: - Clips (sync two takes)

private struct ClipsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        InspectorSection(title: "Line up the takes", systemImage: "arrow.left.and.right") {
            ForEach(0..<min(2, model.slots.count), id: \.self) { i in
                if let item = model.slots[i], item.isVideo {
                    SliderRow(title: "\(i == 0 ? "Left" : "Right") starts at", value: Binding(
                        get: { i < model.offsets.count ? model.offsets[i] : 0 },
                        set: { model.offsets[i] = $0 }
                    ), range: 0...max(0.1, min(15, item.duration - 0.5))) { String(format: "%.2fs", $0) }
                }
            }
            Text("Skip the beginning of a clip so both phones do the same thing at the same time.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Export

private struct ExportSettingsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        InspectorSection(title: "Export for X", systemImage: "square.and.arrow.up") {
            if model.isStill || !model.hasContent {
                HStack {
                    Picker("Format", selection: $model.style.export.imageFormat) {
                        ForEach(ImageFormat.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 120)
                    Picker("Resolution", selection: $model.style.export.imageScale) {
                        Text("1×").tag(1)
                        Text("2×").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 90)
                }
                .labelsHidden()
            }
            if model.isMotion || !model.hasContent {
                LabeledRow("Size") {
                    Picker("Resolution", selection: $model.style.export.resolution) {
                        ForEach(ExportResolution.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                let size = model.style.export.videoSize(for: model.style.canvas)
                Text(model.style.export.resolution == .uhd4K
                     ? "\(Int(size.width))×\(Int(size.height)). 4K uploads need X Premium (web or iPhone app); X shows everyone else a sharp 1080p version."
                     : "\(Int(size.width))×\(Int(size.height))")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                HStack {
                    Picker("Frame rate", selection: $model.style.export.fps) {
                        Text("30 fps").tag(30)
                        Text("60 fps").tag(60)
                    }
                    .pickerStyle(.segmented)
                    Picker("Quality", selection: $model.style.export.quality) {
                        ForEach(ExportQuality.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                .labelsHidden()
                if model.hasAudio {
                    Toggle("Include audio", isOn: $model.style.export.includeAudio)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12))
                }
            }
            Button {
                model.export()
            } label: {
                Label("Export for X", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!model.hasContent || model.isExporting)
            Text(model.isStill
                 ? "sRGB image, so colours look the same on X."
                 : "MP4 · H.264 · BT.709 colour, the format X expects, so colours don't shift.")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }
    }
}
