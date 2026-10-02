import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 0) {
            SidebarView()
                .frame(width: 272)
            Divider()
            VStack(spacing: 0) {
                PreviewArea()
                if model.isMotion {
                    Divider()
                    TransportBar()
                    EditorTimeline()
                        .frame(height: 118)
                }
            }
            .frame(minWidth: 520)
            .background(Color(nsColor: .underPageBackgroundColor))
            Divider()
            InspectorView()
                .frame(width: 318)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Picker("Layout", selection: $model.layout) {
                    Label("Single", systemImage: "iphone").tag(LayoutMode.single)
                    Label("Compare", systemImage: "rectangle.split.2x1").tag(LayoutMode.compare)
                    Label("Tour", systemImage: "square.grid.3x2").tag(LayoutMode.tour)
                }
                .pickerStyle(.segmented)
                .labelStyle(.titleAndIcon)
                .help("One phone · two side by side (light vs dark) · a camera tour of several screens")
            }
            ToolbarItem(placement: .principal) {
                Picker("Canvas", selection: $model.style.canvas) {
                    ForEach(CanvasPreset.allCases) { preset in
                        Text(preset.ratio).tag(preset)
                    }
                }
                .pickerStyle(.segmented)
                .help(model.style.canvas.hint)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if model.isMotion {
                    Button {
                        model.exportCurrentFrame()
                    } label: {
                        Label("Save Frame", systemImage: "photo")
                    }
                    .help("Export the current moment as a high-res image (⇧⌘E)")
                }
                Button {
                    model.export()
                } label: {
                    Label("Export for X", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.hasContent || model.isExporting)
                .help("Render an X-ready file (⌘E)")
            }
        }
        .fileImporter(isPresented: $model.showImporter, allowedContentTypes: [.movie, .video, .image], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.importURLs(urls) }
        }
        .sheet(isPresented: $model.showExportSheet) {
            ExportSheet()
        }
        .sheet(isPresented: $model.showPhoneGallery) {
            PhoneGallerySheet()
        }
        .overlay(alignment: .top) {
            if let banner = model.banner {
                BannerView(banner: banner)
                    .padding(.top, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onTapGesture { model.banner = nil }
            }
        }
        .animation(.spring(duration: 0.35), value: model.banner)
    }
}

struct BannerView: View {
    let banner: Banner

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: banner.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(banner.isError ? .orange : .green)
            Text(banner.text)
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(3)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .frame(maxWidth: 560)
    }
}
