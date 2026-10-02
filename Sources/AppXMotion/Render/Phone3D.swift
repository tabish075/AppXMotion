import AppKit
import CoreImage
import Metal
import SceneKit
import simd

/// Physical proportions of the realistic 3D phone (millimetres).
/// Modelled on the Galaxy S26 Ultra: flat display, squared-off corners, thin uniform bezels,
/// titanium side frame, centred punch-hole camera, keys on the right edge.
struct PhoneSpec {
    let name: String
    let body: CGSize
    let thickness: CGFloat
    let bodyRadius: CGFloat
    let edgeRound: CGFloat
    let screen: CGSize
    let screenRadius: CGFloat
    let punchHoleDiameter: CGFloat
    let punchHoleFromTop: CGFloat

    static let galaxyUltra = PhoneSpec(
        name: "Galaxy S26 Ultra",
        body: CGSize(width: 78.1, height: 163.6),
        thickness: 7.9,
        bodyRadius: 7.4,
        edgeRound: 0.85,
        screen: CGSize(width: 73.5, height: 159.0),
        screenRadius: 4.9,
        punchHoleDiameter: 2.6,
        punchHoleFromTop: 4.3
    )

    var bodyAspect: CGFloat { body.width / body.height }

    /// Same phone with corners scaled (1 = default).
    func withRoundness(_ factor: CGFloat) -> PhoneSpec {
        let f = max(0.3, min(1.6, factor))
        return PhoneSpec(name: name, body: body, thickness: thickness, bodyRadius: max(edgeRound * 1.5, bodyRadius * f), edgeRound: edgeRound,
                         screen: screen, screenRadius: max(0.6, screenRadius * f), punchHoleDiameter: punchHoleDiameter, punchHoleFromTop: punchHoleFromTop)
    }
}

/// Titanium finishes for the 3D phone.
struct PhoneFinish: Identifiable {
    let id: String
    let name: String
    let frame: RGBAColor
    let back: RGBAColor
    let roughness: CGFloat

    static let all: [PhoneFinish] = [
        PhoneFinish(id: "ti-black", name: "Titanium Black", frame: RGBAColor(hex: 0x3A3B3E), back: RGBAColor(hex: 0x1D1E20), roughness: 0.32),
        PhoneFinish(id: "ti-gray", name: "Titanium Gray", frame: RGBAColor(hex: 0x9C9C9A), back: RGBAColor(hex: 0x7D7D7B), roughness: 0.30),
        PhoneFinish(id: "ti-silverblue", name: "Titanium Silverblue", frame: RGBAColor(hex: 0xA9B9CF), back: RGBAColor(hex: 0x8FA3BF), roughness: 0.28),
        PhoneFinish(id: "ti-whitesilver", name: "Titanium Whitesilver", frame: RGBAColor(hex: 0xE2E2DF), back: RGBAColor(hex: 0xD9D9D5), roughness: 0.26),
        PhoneFinish(id: "ti-violet", name: "Titanium Violet", frame: RGBAColor(hex: 0x9F92B8), back: RGBAColor(hex: 0x857AA0), roughness: 0.30),
        PhoneFinish(id: "ti-jetblack", name: "Jet Black", frame: RGBAColor(hex: 0x17171A), back: RGBAColor(hex: 0x0E0E10), roughness: 0.22),
    ]

    static func named(_ id: String) -> PhoneFinish { all.first { $0.id == id } ?? all[0] }
}

enum DevicePose: String, Codable, CaseIterable, Identifiable {
    case front, angled, hero, float

    var id: String { rawValue }
    var label: String {
        switch self {
        case .front: "Front"
        case .angled: "Angled"
        case .hero: "Hero"
        case .float: "Float"
        }
    }

    /// Rotation in degrees (x = lean back, y = turn, z = roll) and a vertical bob in mm at time `t`.
    func transform(at t: Double, mirrored: Bool, laptop: Bool = false) -> (x: Double, y: Double, z: Double, bob: Double) {
        let m = mirrored ? -1.0 : 1.0
        if laptop {
            // Laptops are always seen a little from above so the keyboard deck shows.
            switch self {
            case .front: return (10, 0, 0, 0)
            case .angled: return (10, -26 * m, 0, 0)
            case .hero: return (17, -22 * m, -2 * m, 0)
            case .float:
                let w = 2 * Double.pi * t / 8.0
                return (10 + 2 * sin(w * 1.2), (-15 + 6 * sin(w)) * m, 0.8 * sin(w * 0.8) * m, 2.0 * sin(w * 1.1))
            }
        }
        switch self {
        case .front:
            return (0, 0, 0, 0)
        case .angled:
            return (4, -24 * m, 0, 0)
        case .hero:
            return (-16, -20 * m, -3 * m, 0)
        case .float:
            let w = 2 * Double.pi * t / 7.0
            return (5 + 2.2 * sin(w * 1.3), (-15 + 6 * sin(w)) * m, (1.2 * sin(w * 0.8)) * m, 1.6 * sin(w * 1.1))
        }
    }
}

/// Renders realistic 3D phones with SceneKit. Each frame the recording is drawn onto the phone's screen,
/// and the zoom is done by the 3D camera, so zoomed frames stay sharp.
/// Which 3D device to build.
enum DeviceModel3D {
    case phone(PhoneSpec, PhoneFinish)
    case laptop(LaptopSpec, LaptopFinish)

    var screenSize: CGSize {
        switch self {
        case .phone(let spec, _): spec.screen
        case .laptop(let spec, _): spec.screen
        }
    }
    var isLaptop: Bool { if case .laptop = self { return true }; return false }
}

final class PhoneScene: @unchecked Sendable {
    private let model: DeviceModel3D
    private let screenSize: CGSize
    private let pose: DevicePose
    private let canvas: CGSize
    private let scene = SCNScene()
    private let renderer: SCNRenderer
    private let cameraNode = SCNNode()
    private let camera = SCNCamera()
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    /// Render targets (rotated so Core Image can still be reading the previous frame).
    private var targets: [(color: MTLTexture, view: MTLTexture, msaa: MTLTexture, depth: MTLTexture)] = []
    private var targetIndex = 0
    private var screenTextures: [Int: (size: CGSize, texture: MTLTexture, view: MTLTexture)] = [:]
    /// Screenshots (and frozen video frames) are uploaded once, mipmapped, and reused.
    private var staticTextures: [Int: (id: ObjectIdentifier, view: MTLTexture)] = [:]
    private var lastFrameIDs: [Int: ObjectIdentifier] = [:]
    private var rigs: [(node: SCNNode, screen: SCNMaterial, display: SCNNode, base: SCNVector3, mirrored: Bool, screenPx: CGFloat)] = []
    private let lock = NSLock()
    private let distance: CGFloat
    private let pxPerMM: CGFloat
    private let fov: CGFloat = 16

    /// `screens` are the screen rectangles from the 2D layout (canvas pixels, top-left origin).
    init?(model: DeviceModel3D, pose: DevicePose, canvas: CGSize, screens: [CGRect], roundness: CGFloat = 1) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let first = screens.first, first.height > 0 else { return nil }
        self.device = device
        self.queue = queue
        self.model = model
        self.screenSize = model.screenSize
        self.pose = pose
        self.canvas = canvas
        renderer = SCNRenderer(device: device, options: nil)
        pxPerMM = first.height / model.screenSize.height
        // Camera distance so that 1 mm at z = 0 is `pxPerMM` pixels.
        let visibleHeightMM = canvas.height / pxPerMM
        distance = visibleHeightMM / 2 / tan(fov / 2 * .pi / 180)

        scene.background.contents = NSColor.clear
        scene.lightingEnvironment.contents = Self.studioEnvironment()
        scene.lightingEnvironment.intensity = 1.25

        camera.fieldOfView = fov
        camera.projectionDirection = .vertical
        camera.zNear = Double(max(1, distance - 700))
        camera.zFar = Double(distance + 700)
        camera.wantsHDR = false
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 0, distance)
        scene.rootNode.addChildNode(cameraNode)

        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 420
        key.light?.color = NSColor(white: 1, alpha: 1)
        key.eulerAngles = SCNVector3(-0.7, -0.5, 0)
        scene.rootNode.addChildNode(key)

        for (i, rect) in screens.enumerated() {
            let mirrored = screens.count == 2 && i == 0 // a pair faces each other
            let built: (SCNNode, SCNMaterial, SCNNode)
            switch model {
            case .phone(let spec, let finish): built = Self.buildPhone(spec: spec.withRoundness(roundness), finish: finish)
            case .laptop(let spec, let finish): built = LaptopModel.build(spec: spec, finish: finish)
            }
            let center = CGPoint(x: (rect.midX - canvas.width / 2) / pxPerMM, y: -(rect.midY - canvas.height / 2) / pxPerMM)
            let base = SCNVector3(center.x, center.y, 0)
            built.0.position = base
            scene.rootNode.addChildNode(built.0)
            rigs.append((built.0, built.1, built.2, base, mirrored, rect.width))
        }
        renderer.scene = scene
        renderer.pointOfView = cameraNode
    }

    // MARK: Model

    private static func buildPhone(spec: PhoneSpec, finish: PhoneFinish) -> (SCNNode, SCNMaterial, SCNNode) {
        let root = SCNNode()
        let w = spec.body.width, h = spec.body.height, t = spec.thickness

        // Body: rounded-rect outline extruded to the phone's thickness, with rounded front/back edges.
        let outline = NSBezierPath(roundedRect: CGRect(x: -w / 2, y: -h / 2, width: w, height: h), xRadius: spec.bodyRadius, yRadius: spec.bodyRadius)
        outline.flatness = 0.02
        let shape = SCNShape(path: outline, extrusionDepth: t)
        shape.chamferRadius = spec.edgeRound
        shape.chamferMode = .both
        let profile = NSBezierPath()
        profile.move(to: CGPoint(x: 0, y: 1))
        profile.curve(to: CGPoint(x: 1, y: 0), controlPoint1: CGPoint(x: 0.55, y: 1), controlPoint2: CGPoint(x: 1, y: 0.55))
        profile.flatness = 0.01
        shape.chamferProfile = profile

        let titanium = SCNMaterial()
        titanium.lightingModel = .physicallyBased
        titanium.diffuse.contents = finish.frame.nsColor
        titanium.metalness.contents = 1.0
        titanium.roughness.contents = finish.roughness

        let glass = SCNMaterial()
        glass.lightingModel = .physicallyBased
        glass.diffuse.contents = NSColor(srgbRed: 0.012, green: 0.012, blue: 0.016, alpha: 1)
        glass.metalness.contents = 0.0
        glass.roughness.contents = 0.06

        let backGlass = SCNMaterial()
        backGlass.lightingModel = .physicallyBased
        backGlass.diffuse.contents = finish.back.nsColor
        backGlass.metalness.contents = 0.15
        backGlass.roughness.contents = 0.45

        shape.materials = [glass, backGlass, titanium, titanium, titanium]
        root.addChildNode(SCNNode(geometry: shape))

        // Display: a rounded plane just above the glass.
        let display = SCNPlane(width: spec.screen.width, height: spec.screen.height)
        display.cornerRadius = spec.screenRadius
        display.cornerSegmentCount = 24
        let screen = SCNMaterial()
        screen.lightingModel = .constant
        screen.diffuse.contents = NSColor.black
        screen.diffuse.minificationFilter = .linear
        screen.diffuse.magnificationFilter = .linear
        screen.diffuse.mipFilter = .linear
        screen.diffuse.maxAnisotropy = 8
        screen.isDoubleSided = false
        display.materials = [screen]
        let displayNode = SCNNode(geometry: display)
        displayNode.position = SCNVector3(0, 0, t / 2 + 0.02)
        root.addChildNode(displayNode)

        // Glass reflections on top of the display (additive, so they only brighten).
        let sheen = SCNPlane(width: w - spec.edgeRound * 2, height: h - spec.edgeRound * 2)
        sheen.cornerRadius = spec.bodyRadius - spec.edgeRound
        sheen.cornerSegmentCount = 24
        let sheenMaterial = SCNMaterial()
        sheenMaterial.lightingModel = .physicallyBased
        sheenMaterial.diffuse.contents = NSColor.black
        sheenMaterial.metalness.contents = 0.0
        sheenMaterial.roughness.contents = 0.12
        sheenMaterial.blendMode = .add
        sheenMaterial.writesToDepthBuffer = false
        sheen.materials = [sheenMaterial]
        let sheenNode = SCNNode(geometry: sheen)
        sheenNode.position = SCNVector3(0, 0, t / 2 + 0.05)
        sheenNode.opacity = 0.55
        root.addChildNode(sheenNode)

        // Punch-hole camera.
        let holeRadius = spec.punchHoleDiameter / 2
        let holeY = spec.screen.height / 2 - spec.punchHoleFromTop
        let hole = SCNCylinder(radius: holeRadius, height: 0.02)
        let holeMaterial = SCNMaterial()
        holeMaterial.lightingModel = .physicallyBased
        holeMaterial.diffuse.contents = NSColor(white: 0.01, alpha: 1)
        holeMaterial.roughness.contents = 0.15
        hole.materials = [holeMaterial]
        let holeNode = SCNNode(geometry: hole)
        holeNode.eulerAngles = SCNVector3(CGFloat.pi / 2, 0, 0)
        holeNode.position = SCNVector3(0, holeY, t / 2 + 0.04)
        root.addChildNode(holeNode)
        let lens = SCNCylinder(radius: holeRadius * 0.42, height: 0.02)
        let lensMaterial = SCNMaterial()
        lensMaterial.lightingModel = .physicallyBased
        lensMaterial.diffuse.contents = NSColor(srgbRed: 0.05, green: 0.06, blue: 0.11, alpha: 1)
        lensMaterial.metalness.contents = 0.6
        lensMaterial.roughness.contents = 0.1
        lens.materials = [lensMaterial]
        let lensNode = SCNNode(geometry: lens)
        lensNode.eulerAngles = SCNVector3(CGFloat.pi / 2, 0, 0)
        lensNode.position = SCNVector3(0, holeY, t / 2 + 0.06)
        root.addChildNode(lensNode)

        // Keys on the right edge: volume rocker above the side key.
        func key(length: CGFloat, centerFromTop: CGFloat) {
            let box = SCNBox(width: 1.0, height: length, length: t * 0.34, chamferRadius: 0.45)
            box.materials = [titanium]
            let node = SCNNode(geometry: box)
            node.position = SCNVector3(w / 2 + 0.1, h / 2 - centerFromTop, 0)
            root.addChildNode(node)
        }
        key(length: 21, centerFromTop: 37)
        key(length: 12, centerFromTop: 62)

        // Antenna bands on the frame.
        let band = SCNMaterial()
        band.lightingModel = .physicallyBased
        band.diffuse.contents = finish.frame.mixed(with: .black, 0.35).nsColor
        band.roughness.contents = 0.6
        for (x, y) in [(w / 2, h / 2 - 16), (-w / 2, h / 2 - 16), (w / 2, -h / 2 + 16), (-w / 2, -h / 2 + 16)] {
            let strip = SCNBox(width: 0.12, height: 1.2, length: t * 0.8, chamferRadius: 0)
            strip.materials = [band]
            let node = SCNNode(geometry: strip)
            node.position = SCNVector3(x + (x > 0 ? 0.02 : -0.02), y, 0)
            root.addChildNode(node)
        }

        return (root, screen, displayNode)
    }

    /// Bright photo-studio lighting: light grey cyclorama, a large softbox up-left, a strip light on the right
    /// and a darker floor, which gives metal frames clean highlights and readable edges.
    private static func studioEnvironment() -> CGImage? {
        let w = 1024, h = 512
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: RenderCore.sRGB,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let gradient = CGGradient(colorsSpace: RenderCore.sRGB, colors: [
            CGColor(gray: 0.86, alpha: 1), CGColor(gray: 0.58, alpha: 1), CGColor(gray: 0.30, alpha: 1), CGColor(gray: 0.16, alpha: 1),
        ] as CFArray, locations: [0, 0.42, 0.55, 1])!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: h), end: CGPoint(x: 0, y: 0), options: [])
        func softbox(_ rect: CGRect, _ brightness: CGFloat, blur: CGFloat = 30) {
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: blur, color: CGColor(gray: 1, alpha: brightness))
            ctx.setFillColor(CGColor(gray: brightness, alpha: 1))
            ctx.fill(rect)
            ctx.restoreGState()
        }
        softbox(CGRect(x: 320, y: 300, width: 220, height: 140), 1.0)   // key softbox, up-left of the front
        softbox(CGRect(x: 650, y: 190, width: 50, height: 250), 1.0)    // strip light on the right
        softbox(CGRect(x: 90, y: 230, width: 90, height: 160), 0.85)    // rim light behind-left
        softbox(CGRect(x: 860, y: 230, width: 90, height: 160), 0.8)    // rim light behind-right
        // Dark flags so glass and metal get contrast, not a flat wash.
        ctx.setFillColor(CGColor(gray: 0.08, alpha: 1))
        ctx.fill(CGRect(x: 470, y: 120, width: 120, height: 150))
        ctx.fill(CGRect(x: 0, y: 140, width: 60, height: 200))
        return ctx.makeImage()
    }

    // MARK: Rendering

    /// Canvas position (top-left origin) of a point on a phone's screen, given as 0…1 across and down.
    func canvasPoint(slot: Int, u: Double, v: Double, time: Double) -> CGPoint? {
        guard slot < rigs.count else { return nil }
        lock.lock(); defer { lock.unlock() }
        apply(time: time)
        let local = SCNVector3((CGFloat(u) - 0.5) * screenSize.width, (0.5 - CGFloat(v)) * screenSize.height, 0)
        let world = rigs[slot].display.convertPosition(local, to: nil)
        let z = distance - world.z
        let t = tan(fov / 2 * .pi / 180)
        let ndcY = (world.y / z) / t
        let ndcX = (world.x / z) / (t * canvas.width / canvas.height)
        return CGPoint(x: (ndcX + 1) / 2 * canvas.width, y: (1 - ndcY) / 2 * canvas.height)
    }

    private func apply(time: Double) {
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        defer { SCNTransaction.commit(); SCNTransaction.flush() }
        for rig in rigs {
            let p = pose.transform(at: time, mirrored: rig.mirrored, laptop: model.isLaptop)
            rig.node.eulerAngles = SCNVector3(p.x * .pi / 180, p.y * .pi / 180, p.z * .pi / 180)
            rig.node.position = SCNVector3(rig.base.x, rig.base.y + CGFloat(p.bob), rig.base.z)
            // A turned laptop reaches further out in perspective; keep it inside the frame.
            let s: CGFloat = model.isLaptop && pose != .front ? 0.92 : 1
            rig.node.scale = SCNVector3(s, s, s)
        }
    }

    /// Renders the phones (transparent background) at canvas size.
    /// - Parameters:
    ///   - zoom: the 2D camera (scale and canvas-space centre), recreated here as a real 3D camera move.
    func render(time: Double, frames: [CIImage?], zoomScale: CGFloat, zoomCenter: CGPoint) -> CIImage? {
        lock.lock(); defer { lock.unlock() }
        apply(time: time)

        // Background threads have no run loop, so commit SceneKit changes explicitly.
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        for (i, rig) in rigs.enumerated() {
            if i < frames.count, let frame = frames[i] {
                let target = rig.screenPx * zoomScale * 2
                rig.screen.diffuse.contents = screenTexture(frame, slot: i, targetWidth: target) ?? NSColor.black
            } else {
                rig.screen.diffuse.contents = NSColor(srgbRed: 0.1, green: 0.1, blue: 0.11, alpha: 1)
            }
        }

        // Zoom: aim the camera at the zoom centre and narrow the field of view.
        let cx = (zoomCenter.x - canvas.width / 2) / pxPerMM
        let cy = -(zoomCenter.y - canvas.height / 2) / pxPerMM
        cameraNode.position = SCNVector3(cx, cy, distance)
        camera.fieldOfView = 2 * atan(tan(fov / 2 * .pi / 180) / max(1, zoomScale)) * 180 / .pi
        SCNTransaction.commit()
        SCNTransaction.flush()

        guard let target = nextTarget() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target.msaa
        pass.colorAttachments[0].resolveTexture = target.view
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .multisampleResolve
        pass.depthAttachment.texture = target.depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 1
        pass.depthAttachment.storeAction = .dontCare
        guard let commands = queue.makeCommandBuffer() else { return nil }
        renderer.render(atTime: time, viewport: CGRect(origin: .zero, size: canvas), commandBuffer: commands, passDescriptor: pass)
        commands.commit()
        commands.waitUntilCompleted()

        // Metal is top-left origin, Core Image bottom-left: flip.
        guard let image = CIImage(mtlTexture: target.color, options: [.colorSpace: RenderCore.sRGB]) else { return nil }
        return image.transformed(by: CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -image.extent.height))
    }

    private func nextTarget() -> (color: MTLTexture, view: MTLTexture, msaa: MTLTexture, depth: MTLTexture)? {
        if targets.isEmpty {
            if ProcessInfo.processInfo.environment["PF_DEBUG3D"] != nil {
                print("scenekit color=\(renderer.colorPixelFormat.rawValue) depth=\(renderer.depthPixelFormat.rawValue) stencil=\(renderer.stencilPixelFormat.rawValue)")
            }
            let w = Int(canvas.width.rounded()), h = Int(canvas.height.rounded())
            // One multisample colour + depth buffer (each render finishes before the next), three resolve targets.
            let msaaDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: w, height: h, mipmapped: false)
            msaaDesc.textureType = .type2DMultisample
            msaaDesc.sampleCount = 4
            msaaDesc.usage = .renderTarget
            msaaDesc.storageMode = .private
            let depthDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: renderer.depthPixelFormat == .invalid ? .depth32Float : renderer.depthPixelFormat,
                                                                     width: w, height: h, mipmapped: false)
            depthDesc.textureType = .type2DMultisample
            depthDesc.sampleCount = 4
            depthDesc.usage = .renderTarget
            depthDesc.storageMode = .private
            guard let msaa = device.makeTexture(descriptor: msaaDesc), let depth = device.makeTexture(descriptor: depthDesc) else { return nil }
            for _ in 0..<3 {
                let colorDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
                colorDesc.usage = [.renderTarget, .shaderRead, .pixelFormatView]
                colorDesc.storageMode = .private
                guard let color = device.makeTexture(descriptor: colorDesc),
                      let view = color.makeTextureView(pixelFormat: .bgra8Unorm_srgb) else { return nil }
                targets.append((color, view, msaa, depth))
            }
        }
        targetIndex = (targetIndex + 1) % targets.count
        return targets[targetIndex]
    }

    /// High-resolution, mipmapped copy of a frame that doesn't change (sharp at every zoom level).
    private func staticTexture(_ frame: CIImage, slot: Int) -> MTLTexture? {
        let src = frame.extent
        let screenAspect = screenSize.width / screenSize.height
        var crop = src
        if src.width / src.height > screenAspect {
            let w = src.height * screenAspect
            crop = CGRect(x: src.midX - w / 2, y: src.minY, width: w, height: src.height)
        } else {
            let h = src.width / screenAspect
            crop = CGRect(x: src.minX, y: src.midY - h / 2, width: src.width, height: h)
        }
        let scale = min(1, 1600 / crop.width)
        var image = frame.cropped(to: crop).transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
        if scale < 0.999 {
            image = image.clampedToExtent()
                .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1.0])
        }
        let width = max(1, Int((crop.width * scale).rounded())), height = max(1, Int((crop.height * scale).rounded()))
        image = image.cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: true)
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget, .pixelFormatView]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        let flipped = image.transformed(by: CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -CGFloat(height)))
        let destination = CIRenderDestination(mtlTexture: texture, commandBuffer: nil)
        destination.colorSpace = RenderCore.sRGB
        guard let task = try? RenderCore.context.startTask(toRender: flipped, to: destination), (try? task.waitUntilCompleted()) != nil,
              let commands = queue.makeCommandBuffer(), let blit = commands.makeBlitCommandEncoder() else { return nil }
        blit.generateMipmaps(for: texture)
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        return texture.makeTextureView(pixelFormat: .bgra8Unorm_srgb)
    }

    /// Downscales the recording with Lanczos to roughly its on-screen size (crisp text, no shimmer)
    /// and hands it to SceneKit as an sRGB Metal texture.
    private func screenTexture(_ frame: CIImage, slot: Int, targetWidth: CGFloat) -> MTLTexture? {
        let src = frame.extent
        guard src.width > 0, src.height > 0 else { return nil }
        let id = ObjectIdentifier(frame)
        if let cached = staticTextures[slot], cached.id == id { return cached.view }
        if lastFrameIDs[slot] == id, let view = staticTexture(frame, slot: slot) {
            staticTextures[slot] = (id, view)
            return view
        }
        lastFrameIDs[slot] = id
        // Fill the screen's aspect ratio (crop rather than letterbox).
        let screenAspect = screenSize.width / screenSize.height
        var crop = src
        if src.width / src.height > screenAspect {
            let w = src.height * screenAspect
            crop = CGRect(x: src.midX - w / 2, y: src.minY, width: w, height: src.height)
        } else {
            let h = src.width / screenAspect
            crop = CGRect(x: src.minX, y: src.midY - h / 2, width: src.width, height: h)
        }
        // Round the size up to 64 px steps so the texture can be reused while zooming.
        let quantized = ceil(targetWidth / 64) * 64
        let scale = min(1, quantized / crop.width)
        var image = frame.cropped(to: crop).transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
        if scale < 0.999 {
            image = image.clampedToExtent()
                .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1.0])
        }
        let width = max(1, Int((crop.width * scale).rounded()))
        let height = max(1, Int((crop.height * scale).rounded()))
        image = image.cropped(to: CGRect(x: 0, y: 0, width: width, height: height))

        let size = CGSize(width: width, height: height)
        let texture: MTLTexture, view: MTLTexture
        if let cached = screenTextures[slot], cached.size == size {
            (texture, view) = (cached.texture, cached.view)
        } else {
            // Mipmapped, rendered at ~2× the on-screen size: trilinear sampling keeps UI text crisp at any angle.
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: true)
            descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget, .pixelFormatView]
            descriptor.storageMode = .private
            guard let made = device.makeTexture(descriptor: descriptor), let srgb = made.makeTextureView(pixelFormat: .bgra8Unorm_srgb) else { return nil }
            (texture, view) = (made, srgb)
            screenTextures[slot] = (size, made, srgb)
        }
        // Metal textures are top-left origin; Core Image is bottom-left.
        let flipped = image.transformed(by: CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -CGFloat(height)))
        let destination = CIRenderDestination(mtlTexture: texture, commandBuffer: nil)
        destination.colorSpace = RenderCore.sRGB
        do {
            let task = try RenderCore.context.startTask(toRender: flipped, to: destination)
            _ = try task.waitUntilCompleted()
        } catch {
            return nil
        }
        if texture.mipmapLevelCount > 1, let commands = queue.makeCommandBuffer(), let blit = commands.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: texture)
            blit.endEncoding()
            commands.commit()
            commands.waitUntilCompleted()
        }
        // Same bytes, read as sRGB so SceneKit linearises them correctly.
        return view
    }
}
