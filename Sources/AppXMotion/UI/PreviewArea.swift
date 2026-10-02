import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

struct PreviewArea: View {
    @Environment(AppModel.self) private var model
    @State private var targeted = false

    var body: some View {
        GeometryReader { geo in
            let canvas = model.style.canvas.size
            let available = CGSize(width: max(10, geo.size.width - 48), height: max(10, geo.size.height - 48))
            let scale = min(available.width / canvas.width, available.height / canvas.height)
            let fitted = CGSize(width: canvas.width * scale, height: canvas.height * scale)

            ZStack {
                if model.hasContent {
                    canvasView
                        .frame(width: fitted.width, height: fitted.height)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .shadow(color: .black.opacity(0.22), radius: 18, y: 6)
                        .overlay { ZoomFocusOverlay(canvas: canvas) }
                } else {
                    EmptyStateView()
                }
                if model.isImporting {
                    ProgressView("Loading…")
                        .padding(16)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .overlay {
            if targeted {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                    .padding(10)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            loadFileURLs(providers) { model.importURLs($0) }
            return true
        }
    }

    @ViewBuilder
    private var canvasView: some View {
        if model.isMotion {
            PlayerLayerView(player: model.playback.player)
                .contentShape(Rectangle())
                .onTapGesture { if model.selectedZoomID == nil { model.playback.toggle() } }
        } else if let still = model.stillPreview {
            Image(decorative: still, scale: 1)
                .resizable()
                .interpolation(.high)
        } else {
            Color.clear
        }
    }
}

// MARK: - AVPlayerLayer host

struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerNSView {
        let view = PlayerNSView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ view: PlayerNSView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }
}

final class PlayerNSView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}

// MARK: - Zoom aiming

/// While a zoom is selected, the preview shows the whole canvas and this overlay shows (and lets you drag)
/// the area the zoom will fill.
struct ZoomFocusOverlay: View {
    @Environment(AppModel.self) private var model
    let canvas: CGSize

    var body: some View {
        GeometryReader { geo in
            if let zoom = model.selectedZoom, let viewport = model.viewport(for: zoom) {
                let k = geo.size.width / canvas.width
                let rect = CGRect(x: viewport.minX * k, y: viewport.minY * k, width: viewport.width * k, height: viewport.height * k)
                ZStack(alignment: .topLeading) {
                    Path { p in
                        p.addRect(CGRect(origin: .zero, size: geo.size))
                        p.addRoundedRect(in: rect, cornerSize: CGSize(width: 6, height: 6))
                    }
                    .fill(Color.black.opacity(0.42), style: FillStyle(eoFill: true))

                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)

                    Text("\(String(format: "%.1f", zoom.scale))× zoom · drag to aim")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.accentColor, in: Capsule())
                        .foregroundStyle(.white)
                        .offset(x: rect.minX + 6, y: rect.minY + 6)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            model.updateZoom(zoom.id) {
                                $0.focusX = value.location.x / geo.size.width
                                $0.focusY = value.location.y / geo.size.height
                            }
                        }
                )
            }
        }
    }
}

// MARK: - Empty state

struct EmptyStateView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.98, green: 0.76, blue: 0.92), Color(red: 0.65, green: 0.76, blue: 0.93)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 120, height: 120)
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.black)
                    .frame(width: 46, height: 92)
                    .shadow(color: .black.opacity(0.3), radius: 10, y: 6)
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(0.92))
                    .frame(width: 40, height: 86)
            }
            VStack(spacing: 6) {
                Text(model.isWeb ? "Drop a web app recording or screenshot" : "Drop a screen recording or screenshot")
                    .font(.system(size: 20, weight: .bold))
                Text(model.isWeb ? "…or record any browser window right here (pick it on the left)." : "…or capture it straight from your Android phone.")
                    .foregroundStyle(.secondary)
            }
            if model.isWeb {
                HStack(spacing: 10) {
                    Button { model.toggleWindowRecording() } label: { Label("Record window", systemImage: "record.circle") }
                    Button { model.captureWindowScreenshot() } label: { Label("Screenshot window", systemImage: "camera.viewfinder") }
                }
                .disabled(model.macCapture.selectedWindowID == nil)
                .controlSize(.large)
            } else {
                HStack(spacing: 10) {
                    Button { model.toggleRecording() } label: { Label("Record", systemImage: "record.circle") }
                    Button { model.captureScreenshot() } label: { Label("Screenshot", systemImage: "camera.viewfinder") }
                    Button { model.captureLightDarkScreenshots() } label: { Label("Light + Dark", systemImage: "circle.lefthalf.filled") }
                    Button { model.grabLatestFromPhone() } label: { Label("Latest from phone", systemImage: "arrow.down.circle") }
                }
                .disabled(model.device.device == nil)
                .controlSize(.large)
            }
            Button("Import files…") { model.showImporter = true }
                .buttonStyle(.link)
            VStack(alignment: .leading, spacing: 4) {
                Label("Zooms on taps are added automatically", systemImage: "sparkles")
                Label("Drop 2 files to compare them, or 3+ for a camera tour of your screens", systemImage: "square.grid.3x2")
                Label("Stop a recording and it's exported for X right away (Instant mode)", systemImage: "bolt.fill")
            }
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .padding(.top, 8)
        }
        .padding(40)
    }
}
