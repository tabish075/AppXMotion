import SwiftUI

struct TransportBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let playback = model.playback
        HStack(spacing: 14) {
            Button {
                playback.toggle()
            } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 28, height: 24)
            }
            .buttonStyle(.borderless)
            .help("Play / pause (Space)")

            Text("\(formatTime(playback.currentTime)) / \(formatTime(playback.duration))")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)

            if model.hasVideo {
                Menu {
                    ForEach(StyleSettings.speedOptions, id: \.self) { speed in
                        Button {
                            model.style.speed = speed
                        } label: {
                            if model.style.speed == speed { Label(speedLabel(speed), systemImage: "checkmark") } else { Text(speedLabel(speed)) }
                        }
                    }
                    if !model.compare {
                        Divider()
                        Toggle("Speed up pauses", isOn: Binding(get: { model.style.speedUpPauses }, set: { model.style.speedUpPauses = $0 }))
                    }
                } label: {
                    Label("Speed \(speedLabel(model.style.speed))", systemImage: "hare")
                        .font(.system(size: 12, weight: .medium))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Playback speed of the recording")
            }

            Spacer()

            if model.trimIn > 0.01 || model.trimOut < playback.duration - 0.01 {
                Text("Trimmed to \(String(format: "%.1f", model.trimOut - model.trimIn))s")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                Button("Reset trim") {
                    model.trimIn = 0
                    model.trimOut = playback.duration
                }
                .controlSize(.small)
            }

            if !model.tour {
                Button {
                    model.addZoom()
                } label: {
                    Label("Add zoom", systemImage: "plus.magnifyingglass")
                }
                .controlSize(.small)
                .help("Add a zoom at the playhead (Z)")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Ruler + filmstrip with trim handles + zoom track.
struct EditorTimeline: View {
    @Environment(AppModel.self) private var model
    @State private var dragOrigin: (id: UUID, start: Double, end: Double)?
    @State private var trimOrigin: Double?

    private let pad: CGFloat = 16
    private let rulerH: CGFloat = 20
    private let clipY: CGFloat = 24
    private let clipH: CGFloat = 44
    private let zoomY: CGFloat = 74
    private let zoomH: CGFloat = 30

    var body: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width - pad * 2)
            let duration = max(model.playback.duration, 0.01)
            let x = { (t: Double) -> CGFloat in pad + CGFloat(t / duration) * width }
            let time = { (px: CGFloat) -> Double in min(duration, max(0, Double((px - pad) / width) * duration)) }

            ZStack(alignment: .topLeading) {
                ruler(width: width, duration: duration, x: x)
                    .frame(height: rulerH)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { model.playback.seek(to: time($0.location.x)) })

                clipBar(width: width, x: x, time: time)
                    .offset(y: clipY)

                if model.tour {
                    Text("Camera tour is automatic: overview → each screen → close-ups → overview")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .offset(x: pad + 4, y: zoomY + 8)
                } else {
                    zoomTrack(width: width, duration: duration, x: x, time: time)
                        .offset(y: zoomY)
                }

                // Playhead
                let px = x(model.playback.currentTime)
                Rectangle()
                    .fill(Color.red)
                    .frame(width: 1.5, height: zoomY + zoomH - 2)
                    .offset(x: px - 0.75, y: 2)
                    .allowsHitTesting(false)
                Circle()
                    .fill(Color.red)
                    .frame(width: 9, height: 9)
                    .offset(x: px - 4.5, y: 0)
                    .allowsHitTesting(false)
            }
            .coordinateSpace(name: "timeline")
        }
        .padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: Ruler

    private func ruler(width: CGFloat, duration: Double, x: @escaping (Double) -> CGFloat) -> some View {
        let step: Double = duration > 60 ? 10 : duration > 20 ? 5 : duration > 6 ? 1 : 0.5
        let ticks = Array(stride(from: 0, through: duration, by: step))
        return ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(ticks, id: \.self) { t in
                VStack(alignment: .leading, spacing: 1) {
                    Rectangle().fill(Color.secondary.opacity(0.5)).frame(width: 1, height: 5)
                    Text(t.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(t))s" : String(format: "%.1f", t))
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                .offset(x: x(t))
            }
        }
    }

    // MARK: Clip + trim

    private func clipBar(width: CGFloat, x: @escaping (Double) -> CGFloat, time: @escaping (CGFloat) -> Double) -> some View {
        let inX = x(model.trimIn), outX = x(model.trimOut)
        return ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                ForEach(Array(model.filmstrip.enumerated()), id: \.offset) { _, image in
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: width / CGFloat(max(1, model.filmstrip.count)), height: clipH)
                        .clipped()
                }
            }
            .frame(width: width, height: clipH, alignment: .leading)
            .background(Color.primary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .offset(x: pad)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { model.playback.seek(to: time($0.location.x + pad)) })

            // Dim the trimmed-away parts.
            Rectangle().fill(Color.black.opacity(0.55))
                .frame(width: max(0, inX - pad), height: clipH)
                .offset(x: pad)
                .allowsHitTesting(false)
            Rectangle().fill(Color.black.opacity(0.55))
                .frame(width: max(0, pad + width - outX), height: clipH)
                .offset(x: outX)
                .allowsHitTesting(false)

            // Trim frame + handles.
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.yellow, lineWidth: 2)
                .frame(width: max(8, outX - inX), height: clipH)
                .offset(x: inX)
                .allowsHitTesting(false)
            trimHandle(isIn: true, x: inX, time: time)
            trimHandle(isIn: false, x: outX, time: time)
        }
        .frame(height: clipH)
    }

    private func trimHandle(isIn: Bool, x px: CGFloat, time: @escaping (CGFloat) -> Double) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color.yellow)
            .frame(width: 9, height: clipH)
            .overlay(Capsule().fill(Color.black.opacity(0.45)).frame(width: 2, height: 14))
            .offset(x: isIn ? px : px - 9)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
                    .onChanged { value in
                        let t = time(value.location.x)
                        if isIn {
                            model.trimIn = min(t, model.trimOut - 0.2)
                        } else {
                            model.trimOut = max(t, model.trimIn + 0.2)
                        }
                        model.playback.seek(to: isIn ? model.trimIn : model.trimOut)
                    }
            )
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .help(isIn ? "Trim start (I)" : "Trim end (O)")
    }

    // MARK: Zoom track

    private func zoomTrack(width: CGFloat, duration: Double, x: @escaping (Double) -> CGFloat, time: @escaping (CGFloat) -> Double) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.05))
                .frame(width: width, height: zoomH)
                .overlay(alignment: .leading) {
                    if model.zooms.isEmpty {
                        Text("Zoom track: double-click to add a zoom here, or press Z")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 10)
                    }
                }
                .offset(x: pad)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { location in model.addZoom(at: time(location.x + pad) - 0.3) }
                .simultaneousGesture(TapGesture().onEnded { model.selectedZoomID = nil })

            ForEach(model.zooms) { zoom in
                zoomBlock(zoom, duration: duration, x: x, width: width)
            }
        }
        .frame(height: zoomH)
        .coordinateSpace(name: "zoomtrack")
    }

    private func zoomBlock(_ zoom: ZoomSegment, duration: Double, x: @escaping (Double) -> CGFloat, width: CGFloat) -> some View {
        let selected = model.selectedZoomID == zoom.id
        let x0 = x(zoom.start), x1 = x(zoom.end)
        let secondsPerPoint = duration / Double(width)

        return ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(LinearGradient(colors: [Color.purple, Color.indigo], startPoint: .leading, endPoint: .trailing).opacity(selected ? 1 : 0.75))
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.white.opacity(selected ? 0.9 : 0), lineWidth: 2)
            HStack(spacing: 3) {
                Image(systemName: "plus.magnifyingglass").font(.system(size: 9, weight: .bold))
                Text(String(format: "%.1f×", zoom.scale)).font(.system(size: 10.5, weight: .bold))
                if zoom.isAuto { Image(systemName: "sparkles").font(.system(size: 8, weight: .bold)) }
            }
            .foregroundStyle(.white)
            .lineLimit(1)
        }
        .frame(width: max(14, x1 - x0), height: zoomH)
        .overlay(alignment: .leading) { edgeHandle(zoom, leading: true, secondsPerPoint: secondsPerPoint, duration: duration) }
        .overlay(alignment: .trailing) { edgeHandle(zoom, leading: false, secondsPerPoint: secondsPerPoint, duration: duration) }
        .offset(x: x0)
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in
                    if dragOrigin?.id != zoom.id { dragOrigin = (zoom.id, zoom.start, zoom.end) }
                    guard let origin = dragOrigin else { return }
                    let length = origin.end - origin.start
                    let start = min(max(0, origin.start + Double(value.translation.width) * secondsPerPoint), duration - length)
                    model.updateZoom(zoom.id) { $0.start = start; $0.end = start + length }
                }
                .onEnded { _ in dragOrigin = nil }
        )
        .simultaneousGesture(TapGesture().onEnded {
            model.selectedZoomID = zoom.id
            model.playback.seek(to: zoom.start + min(model.style.zoomRamp, zoom.duration / 2) + 0.05)
        })
        .contextMenu {
            Button("Delete zoom", role: .destructive) { model.deleteZoom(zoom.id) }
        }
    }

    private func edgeHandle(_ zoom: ZoomSegment, leading: Bool, secondsPerPoint: Double, duration: Double) -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.001))
            .frame(width: 8)
            .overlay(Capsule().fill(Color.white.opacity(0.85)).frame(width: 2, height: 12))
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .highPriorityGesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if dragOrigin?.id != zoom.id { dragOrigin = (zoom.id, zoom.start, zoom.end) }
                        guard let origin = dragOrigin else { return }
                        let delta = Double(value.translation.width) * secondsPerPoint
                        model.updateZoom(zoom.id) {
                            if leading {
                                $0.start = min(max(0, origin.start + delta), origin.end - 0.4)
                            } else {
                                $0.end = max(min(duration, origin.end + delta), origin.start + 0.4)
                            }
                        }
                    }
                    .onEnded { _ in dragOrigin = nil }
            )
    }
}
