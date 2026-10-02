import CoreImage
import CoreImage.CIFilterBuiltins

struct RenderParams {
    var canvasSize: CGSize
    var style: StyleSettings
    var mode: LayoutMode
    /// Width / height of the media in each phone slot.
    var aspects: [CGFloat]
    /// Screenshots for image slots (video slots get frames at render time).
    var stills: [CIImage?]
    /// Slots with no media yet (drawn as "drop here" screens in the preview).
    var placeholders: Set<Int> = []
    var zooms: [ZoomSegment] = []
    var zoomEnabled = true
    /// Camera tour timing (tour mode).
    var tour: TourPlan?
    /// Per slot: fraction of the recording trimmed off the top (browser toolbar).
    var crops: [CGFloat] = []
    /// Per slot: clicks to show as ripples (output time, position on the visible content).
    var clicks: [[ClickMark]] = []
}

struct ClickMark: Hashable {
    var time: Double
    var u: Double
    var v: Double
}

/// Composes one output frame: background, phones, screen content, text, and the zoom "camera".
/// Immutable after creation, so it can be shared with the video compositor thread.
final class SceneRenderer: @unchecked Sendable {
    let canvasSize: CGSize
    let layout: SceneLayout
    let style: StyleSettings
    private let zooms: [ZoomSegment]
    private let zoomEnabled: Bool
    private let stills: [CIImage?]
    private let crops: [CGFloat]
    private let clicks: [[ClickMark]]
    private let statusBar: StatusBarCleaner?
    private let background: CIImage
    private let under: CIImage
    private let over: CIImage
    /// Sharper copies of the phone layers for zoomed-in frames.
    private let hiRes: (under: CIImage, over: CIImage, scale: CGFloat)?
    /// Realistic 3D phones (when the S26 Ultra frame is selected).
    private let phone3D: PhoneScene?
    /// Pre-planned camera moves for tours.
    private let cameraPath: [CameraKey]?

    init(_ p: RenderParams) {
        canvasSize = p.canvasSize
        style = p.style
        crops = p.crops
        clicks = p.style.device.showClicks ? p.clicks : []
        let cleaner = p.style.cleanStatusBar && p.style.device.style.platform == .android ? StatusBarCleaner() : nil
        statusBar = cleaner
        stills = p.stills.enumerated().map { i, still in
            still.map { image in
                let cropped = Self.crop(image, i < p.crops.count ? p.crops[i] : 0)
                return cleaner?.apply(cropped) ?? cropped
            }
        }
        zooms = p.zooms.sorted { $0.start < $1.start }
        zoomEnabled = p.zoomEnabled
        let layout = SceneLayout.make(canvas: p.canvasSize, style: p.style, mode: p.mode, aspects: p.aspects)
        self.layout = layout
        cameraPath = p.tour.map { TourCamera.keys(plan: $0, layout: layout) }

        let canvasRect = CGRect(origin: .zero, size: p.canvasSize)
        func ci(_ image: CGImage?) -> CIImage { image.map { CIImage(cgImage: $0) } ?? CIImage.empty() }

        background = ci(ScenePainter.background(size: p.canvasSize, settings: p.style.background)).cropped(to: canvasRect)
        under = ci(ScenePainter.underLayer(layout: layout, style: p.style, scale: 1, placeholders: p.placeholders))
        over = ci(ScenePainter.overLayer(layout: layout, style: p.style, scale: 1))

        switch p.style.device.style {
        case .galaxy3D:
            phone3D = PhoneScene(model: .phone(.galaxyUltra, PhoneFinish.named(p.style.device.finishID)), pose: p.style.device.pose,
                                 canvas: p.canvasSize, screens: layout.devices.map(\.screen), roundness: CGFloat(p.style.device.roundness))
        case .macbook3D:
            phone3D = PhoneScene(model: .laptop(.macbookPro, LaptopFinish.named(p.style.device.laptopFinishID)), pose: p.style.device.pose,
                                 canvas: p.canvasSize, screens: layout.devices.map(\.screen))
        default:
            phone3D = nil
        }

        var maxZoom = p.zoomEnabled ? (p.zooms.map(\.scale).max() ?? 1) : 1
        if let cameraPath, p.zoomEnabled { maxZoom = max(maxZoom, cameraPath.map { Double($0.scale) }.max() ?? 1) }
        if maxZoom > 1.05 {
            // Sharper copies for zoomed frames, capped at ~36 MP so 4K canvases stay light on memory.
            let pixels = p.canvasSize.width * p.canvasSize.height
            let scale = CGFloat(min(2.5, maxZoom, max(1.05, (36_000_000 / pixels).squareRoot())))
            hiRes = (ci(ScenePainter.underLayer(layout: layout, style: p.style, scale: scale, placeholders: p.placeholders)),
                     ci(ScenePainter.overLayer(layout: layout, style: p.style, scale: scale)),
                     scale)
        } else {
            hiRes = nil
        }
    }

    // MARK: Camera

    /// Zoom level and the canvas point (top-left origin) at the centre of the view.
    func camera(at time: Double) -> (scale: CGFloat, center: CGPoint) {
        let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        guard zoomEnabled else { return (1, center) }
        if let cameraPath {
            let cam = TourCamera.sample(cameraPath, at: time)
            return (cam.scale, clamp(cam.center, scale: cam.scale))
        }
        for (index, zoom) in zooms.enumerated() where time >= zoom.start && time <= zoom.end {
            let ramp = min(style.zoomRamp, zoom.duration / 2)
            let target = CGFloat(max(1, zoom.scale))
            let focus = clamp(focusPoint(zoom, time: time), scale: target)
            let previous = index > 0 ? zooms[index - 1] : nil
            let next = index + 1 < zooms.count ? zooms[index + 1] : nil
            // Back-to-back zooms hand over directly: the camera pans from one to the next.
            let joinedPrevious = previous.map { zoom.start - $0.end < 0.15 } ?? false
            if let next, next.start - zoom.end < 0.15, ramp > 0.001, time > zoom.end - ramp {
                let q = CGFloat(Self.ease((time - (zoom.end - ramp)) / ramp))
                let nextScale = CGFloat(max(1, next.scale))
                let nextFocus = clamp(focusPoint(next, time: time), scale: nextScale)
                let scale = exp(log(target) + (log(nextScale) - log(target)) * q)
                let mid = CGPoint(x: focus.x + (nextFocus.x - focus.x) * q, y: focus.y + (nextFocus.y - focus.y) * q)
                return (scale, clamp(mid, scale: scale))
            }
            var p: Double = 1
            if ramp > 0.001 {
                if time < zoom.start + ramp && !joinedPrevious {
                    p = Self.ease((time - zoom.start) / ramp)
                } else if time > zoom.end - ramp {
                    p = Self.ease((zoom.end - time) / ramp)
                }
            }
            let scale = 1 + (target - 1) * CGFloat(p)
            let mid = CGPoint(x: center.x + (focus.x - center.x) * CGFloat(p), y: center.y + (focus.y - center.y) * CGFloat(p))
            return (scale, clamp(mid, scale: scale))
        }
        return (1, center)
    }

    /// Where a zoom points, in canvas pixels. Screen-anchored zooms follow the phone (including 3D angles).
    func focusPoint(_ zoom: ZoomSegment, time: Double) -> CGPoint {
        guard let slot = zoom.anchorSlot, slot < layout.devices.count else {
            return CGPoint(x: zoom.focusX * canvasSize.width, y: zoom.focusY * canvasSize.height)
        }
        var point: CGPoint
        if let phone3D, let projected = phone3D.canvasPoint(slot: slot, u: zoom.anchorU, v: zoom.anchorV, time: time) {
            point = projected
        } else {
            let screen = layout.devices[slot].screen
            point = CGPoint(x: screen.minX + CGFloat(zoom.anchorU) * screen.width, y: screen.minY + CGFloat(zoom.anchorV) * screen.height)
        }
        // With two phones side by side, stay centred so both remain visible.
        if layout.devices.count > 1 { point.x = canvasSize.width / 2 }
        return point
    }

    /// The visible region of the canvas for a zoom (top-left origin), used by the editor overlay.
    func viewport(for zoom: ZoomSegment) -> CGRect {
        let scale = CGFloat(max(1, zoom.scale))
        let c = clamp(focusPoint(zoom, time: zoom.start + min(style.zoomRamp, zoom.duration / 2)), scale: scale)
        let w = canvasSize.width / scale, h = canvasSize.height / scale
        return CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h)
    }

    private func clamp(_ p: CGPoint, scale: CGFloat) -> CGPoint {
        let hw = canvasSize.width / (2 * scale), hh = canvasSize.height / (2 * scale)
        return CGPoint(x: min(max(p.x, hw), canvasSize.width - hw), y: min(max(p.y, hh), canvasSize.height - hh))
    }

    static func ease(_ x: Double) -> Double {
        let t = min(1, max(0, x))
        return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }

    // MARK: Rendering

    /// - Parameter frames: one frame per slot (nil = use the still image or leave the screen dark).
    func render(time: Double, frames: [CIImage?]) -> CIImage {
        let W = canvasSize.width, H = canvasSize.height
        let canvasRect = CGRect(origin: .zero, size: canvasSize)
        func content(_ i: Int) -> CIImage? {
            if i < frames.count, let frame = frames[i] {
                let cropped = Self.crop(frame, i < crops.count ? crops[i] : 0)
                return statusBar?.apply(cropped) ?? cropped
            }
            return i < stills.count ? stills[i] : nil
        }

        var image = background
        if style.background.style == .blurredApp,
           let source = (0..<max(frames.count, stills.count)).lazy.compactMap({ content($0) }).first {
            image = blurredBackdrop(source).composited(over: image)
        }

        let cam = camera(at: time)
        let s = cam.scale
        let viewCenter = CGPoint(x: cam.center.x, y: H - cam.center.y) // Core Image is bottom-left origin
        let camera = CGAffineTransform(translationX: -viewCenter.x, y: -viewCenter.y)
            .concatenating(CGAffineTransform(scaleX: s, y: s))
            .concatenating(CGAffineTransform(translationX: W / 2, y: H / 2))

        let layers: (under: CIImage, over: CIImage, scale: CGFloat) =
            (s > 1.001 ? hiRes : nil) ?? (under, over, 1)
        let layerTransform = CGAffineTransform(scaleX: 1 / layers.scale, y: 1 / layers.scale).concatenating(camera)

        if let phone3D {
            let contents = layout.devices.indices.map { content($0) }
            if let phones = phone3D.render(time: time, frames: contents, zoomScale: s, zoomCenter: cam.center) {
                if style.shadow.enabled && style.shadow.strength > 0.01 {
                    image = shadow(for: phones, zoom: s).composited(over: image)
                }
                image = phones.composited(over: image)
            }
            image = ripples(at: time, camera: camera, scale: s).composited(over: image)
            image = layers.over.transformed(by: layerTransform).composited(over: image)
            return image.cropped(to: canvasRect)
        }

        image = layers.under.transformed(by: layerTransform).composited(over: image)

        for (i, dev) in layout.devices.enumerated() {
            guard let frame = content(i) else { continue }
            let screen = CGRect(x: dev.screen.minX, y: H - dev.screen.maxY, width: dev.screen.width, height: dev.screen.height)
                .applying(camera)
            image = place(frame, in: screen, radius: dev.screenRadius * s, squareTop: dev.squareTop).composited(over: image)
        }
        image = ripples(at: time, camera: camera, scale: s).composited(over: image)

        image = layers.over.transformed(by: layerTransform).composited(over: image)
        return image.cropped(to: canvasRect)
    }

    /// Scales the recording into the screen with Lanczos (keeps UI text crisp) and rounds the corners.
    static func crop(_ image: CIImage, _ top: CGFloat) -> CIImage {
        guard top > 0.0005 else { return image }
        let e = image.extent
        return image.cropped(to: CGRect(x: e.minX, y: e.minY, width: e.width, height: e.height * (1 - top)))
            .transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
    }

    /// Soft expanding dots where you clicked (web recordings).
    private func ripples(at time: Double, camera: CGAffineTransform, scale: CGFloat) -> CIImage {
        var out = CIImage.empty()
        let H = canvasSize.height
        let duration = 0.55
        for (slot, marks) in clicks.enumerated() where slot < layout.devices.count {
            for mark in marks where time >= mark.time && time <= mark.time + duration {
                let age = (time - mark.time) / duration
                var point: CGPoint
                if let phone3D, let projected = phone3D.canvasPoint(slot: slot, u: mark.u, v: mark.v, time: time) {
                    point = projected
                } else {
                    let screen = layout.devices[slot].screen
                    point = CGPoint(x: screen.minX + CGFloat(mark.u) * screen.width, y: screen.minY + CGFloat(mark.v) * screen.height)
                }
                let center = CGPoint(x: point.x, y: H - point.y).applying(camera)
                let radius = layout.unit * 0.032 * scale * CGFloat(0.45 + 0.75 * age)
                let alpha = 0.42 * (1 - age)
                let glow = CIFilter(name: "CIRadialGradient", parameters: [
                    "inputCenter": CIVector(x: center.x, y: center.y),
                    "inputRadius0": radius * 0.35,
                    "inputRadius1": radius,
                    "inputColor0": CIColor(red: 0.15, green: 0.39, blue: 0.92, alpha: alpha),
                    "inputColor1": CIColor(red: 0.15, green: 0.39, blue: 0.92, alpha: 0),
                ])?.outputImage?.cropped(to: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                if let glow { out = glow.composited(over: out) }
            }
        }
        return out
    }

    private func place(_ frame: CIImage, in target: CGRect, radius: CGFloat, squareTop: Bool = false) -> CIImage {
        let src = frame.extent
        guard src.width > 0, src.height > 0, target.width > 0, target.height > 0 else { return .empty() }
        let scale = max(target.width / src.width, target.height / src.height)
        let normalized = frame.transformed(by: CGAffineTransform(translationX: -src.minX, y: -src.minY))
        var scaled = normalized.clampedToExtent()
            .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1.0])
            .cropped(to: CGRect(x: 0, y: 0, width: src.width * scale, height: src.height * scale))
        let e = scaled.extent
        scaled = scaled.transformed(by: CGAffineTransform(translationX: target.midX - e.midX, y: target.midY - e.midY))

        let mask = CIFilter.roundedRectangleGenerator()
        mask.extent = target
        mask.radius = Float(min(radius, min(target.width, target.height) / 2))
        mask.color = .white
        guard var maskImage = mask.outputImage else { return scaled.cropped(to: target) }
        if squareTop {
            // Only the bottom corners are rounded (the top meets the browser's address bar).
            let top = CGRect(x: target.minX, y: target.midY, width: target.width, height: target.height / 2)
            maskImage = CIImage(color: .white).cropped(to: top).composited(over: maskImage)
        }
        return scaled.applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: maskImage])
    }

    /// Soft shadow cast by the 3D phones: a wide ambient shadow plus a tight contact shadow, built from their silhouette.
    private func shadow(for phones: CIImage, zoom: CGFloat) -> CIImage {
        let u = layout.unit * zoom
        let strength = CGFloat(style.shadow.strength)
        let soft = CGFloat(style.shadow.softness)
        // Work at quarter resolution: the shadow is blurry anyway, and this is ~10× cheaper.
        let down: CGFloat = 0.25
        let silhouette = phones.transformed(by: CGAffineTransform(scaleX: down, y: down))
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ])
        let small = CGRect(x: 0, y: 0, width: canvasSize.width * down, height: canvasSize.height * down)
        func layer(opacity: CGFloat, blur: CGFloat, drop: CGFloat) -> CIImage {
            silhouette
                .applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: min(1, opacity))])
                .clampedToExtent()
                .applyingGaussianBlur(sigma: max(0.5, blur * down))
                // Keep a margin so shifting the shadow down doesn't leave an empty strip at the top.
                .cropped(to: small.insetBy(dx: -small.width * 0.25, dy: -small.height * 0.25))
                .transformed(by: CGAffineTransform(scaleX: 1 / down, y: 1 / down))
                .transformed(by: CGAffineTransform(translationX: 0, y: -drop))
                .cropped(to: CGRect(origin: .zero, size: canvasSize))
        }
        let ambient = layer(opacity: 0.34 * strength, blur: u * (0.025 + 0.04 * soft), drop: u * (0.02 + 0.03 * soft))
        let contact = layer(opacity: 0.30 * strength, blur: u * (0.005 + 0.008 * soft), drop: u * (0.004 + 0.006 * soft))
        return contact.composited(over: ambient)
    }

    /// The app's own screen, hugely blurred, as a background that always matches the app's colours.
    private func blurredBackdrop(_ source: CIImage) -> CIImage {
        let W = canvasSize.width, H = canvasSize.height
        let canvasRect = CGRect(origin: .zero, size: canvasSize)
        let e = source.extent
        guard e.width > 0, e.height > 0 else { return .empty() }
        let fill = max(W / e.width, H / e.height) * 1.15
        let down: CGFloat = 0.1

        var img = source.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .transformed(by: CGAffineTransform(scaleX: fill * down, y: fill * down))
        let small = img.extent
        img = img.clampedToExtent().applyingGaussianBlur(sigma: 9).cropped(to: small)
            .transformed(by: CGAffineTransform(scaleX: 1 / down, y: 1 / down))
        let big = img.extent
        img = img.transformed(by: CGAffineTransform(translationX: W / 2 - big.midX, y: H / 2 - big.midY))
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.35, kCIInputBrightnessKey: -0.04])
        let veil = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.16)).cropped(to: canvasRect)
        return veil.composited(over: img).cropped(to: canvasRect)
    }

    func makeCGImage(time: Double = 0, frames: [CIImage?] = []) -> CGImage? {
        RenderCore.context.createCGImage(render(time: time, frames: frames), from: CGRect(origin: .zero, size: canvasSize),
                                         format: .RGBA8, colorSpace: RenderCore.sRGB)
    }
}
