import SwiftUI

struct ExportSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 18) {
            switch model.exportPhase {
            case .running(let progress):
                VStack(spacing: 14) {
                    Text("Rendering for X…").font(.system(size: 17, weight: .semibold))
                    ProgressView(value: progress)
                        .frame(width: 320)
                    Text("\(Int(progress * 100))%").monospacedDigit().foregroundStyle(.secondary)
                    Button("Cancel") { model.cancelExport() }
                        .keyboardShortcut(.cancelAction)
                }
                .padding(30)
            case .done:
                if let result = model.lastExport {
                    ResultView(result: result)
                }
            case .idle:
                ProgressView()
            }
        }
        .frame(minWidth: 460)
    }
}

private struct ResultView: View {
    @Environment(AppModel.self) private var model
    let result: ExportResult

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Ready for X").font(.system(size: 17, weight: .semibold))
            }

            Group {
                if let thumb = result.thumbnail {
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.2))
                }
            }
            .frame(maxWidth: 380, maxHeight: 380)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
            .overlay(alignment: .bottomTrailing) {
                if result.isVideo {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.white, .black.opacity(0.5))
                        .padding(8)
                }
            }
            .onDrag { NSItemProvider(contentsOf: result.url) ?? NSItemProvider() }
            .help("Drag this straight into the X composer in your browser")

            VStack(spacing: 3) {
                Text(result.url.lastPathComponent).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text(details).font(.system(size: 11)).foregroundStyle(.secondary)
                Text("Tip: drag the preview above straight into the X composer.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button { model.revealExport() } label: { Label("Show in Finder", systemImage: "folder") }
                Button { model.copyExportToClipboard() } label: { Label("Copy", systemImage: "doc.on.doc") }
                Button { model.openXComposer() } label: { Label("Open X", systemImage: "arrow.up.right.square") }
                Spacer()
                Button("Done") { model.showExportSheet = false; model.exportPhase = .idle }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private var details: String {
        var parts = ["\(Int(result.pixelSize.width))×\(Int(result.pixelSize.height))", formatBytes(result.bytes)]
        if let d = result.duration { parts.insert(String(format: "%.1fs", d), at: 0) }
        if result.isVideo && result.bytes > 512 * 1024 * 1024 { parts.append("⚠︎ over X's 512 MB limit") }
        if let d = result.duration, d > 140 { parts.append("longer than 2:20 needs X Premium") }
        return parts.joined(separator: " · ")
    }
}

struct PhoneGallerySheet: View {
    @Environment(AppModel.self) private var model
    @State private var selection: RemoteMedia.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("On your phone").font(.system(size: 16, weight: .semibold))
                    Text("Latest screen recordings and screenshots").font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.loadPhoneGallery() } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(model.loadingGallery)
            }

            if model.loadingGallery {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.phoneGallery.isEmpty {
                Text("Nothing found in Movies, DCIM or Pictures/Screenshots.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.phoneGallery, selection: $selection) { media in
                    HStack(spacing: 10) {
                        Image(systemName: media.isVideo ? "video.fill" : "photo.fill")
                            .foregroundStyle(media.isVideo ? Color.red : Color.blue)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(media.name).lineLimit(1).truncationMode(.middle)
                            Text("\(media.modified.formatted(.relative(presentation: .named))) · \(formatBytes(media.size))")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.tour {
                            Button("Add") { model.importFromPhone(media, slot: model.slots.count) }
                                .controlSize(.small)
                        } else {
                            Button(model.compare ? "Left" : "Import") { model.importFromPhone(media, slot: 0); model.showPhoneGallery = false }
                                .controlSize(.small)
                        }
                        if model.compare {
                            Button("Right") { model.importFromPhone(media, slot: 1); model.showPhoneGallery = false }
                                .controlSize(.small)
                        }
                    }
                    .padding(.vertical, 2)
                    .contextMenu {
                        Button("Import") { model.importFromPhone(media, slot: model.selectedSlot) }
                    }
                }
                .listStyle(.inset)
            }

            HStack {
                Spacer()
                Button("Close") { model.showPhoneGallery = false }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 480)
    }
}
