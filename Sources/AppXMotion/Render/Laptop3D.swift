import AppKit
import SceneKit

/// Proportions of the 3D laptop (millimetres), modelled on a 14-inch MacBook Pro.
struct LaptopSpec {
    let lid: CGSize
    let lidThickness: CGFloat
    let screen: CGSize
    let topBezel: CGFloat
    let cornerRadius: CGFloat
    let baseDepth: CGFloat
    let baseThickness: CGFloat
    /// How far the lid leans back from vertical, in degrees.
    let lidTilt: CGFloat

    var chin: CGFloat { lid.height - topBezel - screen.height }

    static let macbookPro = LaptopSpec(
        lid: CGSize(width: 312.6, height: 216.5),
        lidThickness: 4.6,
        screen: CGSize(width: 302.0, height: 196.2),
        topBezel: 6.3,
        cornerRadius: 11,
        baseDepth: 221.2,
        baseThickness: 10.9,
        lidTilt: 13
    )
}

struct LaptopFinish: Identifiable {
    let id: String
    let name: String
    let body: RGBAColor
    let keys: RGBAColor

    static let all: [LaptopFinish] = [
        LaptopFinish(id: "space-black", name: "Space Black", body: RGBAColor(hex: 0x2F2F32), keys: RGBAColor(hex: 0x0E0E10)),
        LaptopFinish(id: "silver", name: "Silver", body: RGBAColor(hex: 0xDADBDD), keys: RGBAColor(hex: 0x151517)),
        LaptopFinish(id: "midnight", name: "Midnight", body: RGBAColor(hex: 0x2E3542), keys: RGBAColor(hex: 0x101217)),
        LaptopFinish(id: "starlight", name: "Starlight", body: RGBAColor(hex: 0xE3DACB), keys: RGBAColor(hex: 0x17171A)),
    ]

    static func named(_ id: String) -> LaptopFinish { all.first { $0.id == id } ?? all[0] }
}

enum LaptopModel {
    /// Builds the laptop with the centre of its display at the origin, so poses rotate around the screen.
    static func build(spec: LaptopSpec, finish: LaptopFinish) -> (root: SCNNode, screen: SCNMaterial, display: SCNNode) {
        let w = spec.lid.width
        let model = SCNNode()

        let aluminum = SCNMaterial()
        aluminum.lightingModel = .physicallyBased
        aluminum.diffuse.contents = finish.body.nsColor
        aluminum.metalness.contents = 1.0
        aluminum.roughness.contents = 0.38

        let glass = SCNMaterial()
        glass.lightingModel = .physicallyBased
        glass.diffuse.contents = NSColor(srgbRed: 0.012, green: 0.012, blue: 0.016, alpha: 1)
        glass.metalness.contents = 0.0
        glass.roughness.contents = 0.08

        func roundedProfile() -> NSBezierPath {
            let profile = NSBezierPath()
            profile.move(to: CGPoint(x: 0, y: 1))
            profile.curve(to: CGPoint(x: 1, y: 0), controlPoint1: CGPoint(x: 0.55, y: 1), controlPoint2: CGPoint(x: 1, y: 0.55))
            profile.flatness = 0.01
            return profile
        }

        // Base: a slab lying flat, back edge at z = 0, front edge towards the viewer (+z), top surface at y = 0.
        let basePath = NSBezierPath(roundedRect: CGRect(x: -w / 2, y: 0, width: w, height: spec.baseDepth), xRadius: spec.cornerRadius, yRadius: spec.cornerRadius)
        basePath.flatness = 0.05
        let baseShape = SCNShape(path: basePath, extrusionDepth: spec.baseThickness)
        baseShape.chamferRadius = 1.4
        baseShape.chamferMode = .both
        baseShape.chamferProfile = roundedProfile()
        baseShape.materials = [aluminum]
        let base = SCNNode(geometry: baseShape)
        base.eulerAngles.x = .pi / 2
        base.position = SCNVector3(0, -spec.baseThickness / 2, 0)
        model.addChildNode(base)

        // Keyboard well and trackpad on the deck.
        let keyboard = SCNPlane(width: w * 0.86, height: spec.baseDepth * 0.47)
        let keyMaterial = SCNMaterial()
        keyMaterial.lightingModel = .physicallyBased
        keyMaterial.diffuse.contents = keyboardImage(finish: finish)
        keyMaterial.roughness.contents = 0.65
        keyMaterial.metalness.contents = 0.0
        keyboard.materials = [keyMaterial]
        let keyboardNode = SCNNode(geometry: keyboard)
        keyboardNode.eulerAngles.x = -.pi / 2
        keyboardNode.position = SCNVector3(0, 0.05, spec.baseDepth * 0.30)
        model.addChildNode(keyboardNode)

        let trackpad = SCNPlane(width: w * 0.42, height: spec.baseDepth * 0.36)
        trackpad.cornerRadius = 4
        let padMaterial = SCNMaterial()
        padMaterial.lightingModel = .physicallyBased
        padMaterial.diffuse.contents = finish.body.mixed(with: .black, 0.06).nsColor
        padMaterial.metalness.contents = 0.6
        padMaterial.roughness.contents = 0.25
        trackpad.materials = [padMaterial]
        let trackpadNode = SCNNode(geometry: trackpad)
        trackpadNode.eulerAngles.x = -.pi / 2
        trackpadNode.position = SCNVector3(0, 0.05, spec.baseDepth * 0.74)
        model.addChildNode(trackpadNode)

        // Hinge.
        let hinge = SCNCylinder(radius: 2.6, height: w * 0.84)
        let hingeMaterial = SCNMaterial()
        hingeMaterial.lightingModel = .physicallyBased
        hingeMaterial.diffuse.contents = finish.body.mixed(with: .black, 0.45).nsColor
        hingeMaterial.metalness.contents = 0.8
        hingeMaterial.roughness.contents = 0.4
        hinge.materials = [hingeMaterial]
        let hingeNode = SCNNode(geometry: hinge)
        hingeNode.eulerAngles.z = .pi / 2
        hingeNode.position = SCNVector3(0, -1.2, 1.5)
        model.addChildNode(hingeNode)

        // Lid, pivoting at the back edge of the base.
        let lidPivot = SCNNode()
        lidPivot.position = SCNVector3(0, 0.4, 2.0)
        lidPivot.eulerAngles.x = -spec.lidTilt * .pi / 180
        model.addChildNode(lidPivot)

        let lidPath = NSBezierPath(roundedRect: CGRect(x: -w / 2, y: 0, width: w, height: spec.lid.height), xRadius: spec.cornerRadius, yRadius: spec.cornerRadius)
        lidPath.flatness = 0.05
        let lidShape = SCNShape(path: lidPath, extrusionDepth: spec.lidThickness)
        lidShape.chamferRadius = 1.0
        lidShape.chamferMode = .both
        lidShape.chamferProfile = roundedProfile()
        lidShape.materials = [glass, aluminum, aluminum, aluminum, aluminum]
        let lid = SCNNode(geometry: lidShape)
        lid.position = SCNVector3(0, 0, -spec.lidThickness / 2)
        lidPivot.addChildNode(lid)

        // Display.
        let display = SCNPlane(width: spec.screen.width, height: spec.screen.height)
        display.cornerRadius = 3.5
        display.cornerSegmentCount = 12
        let screen = SCNMaterial()
        screen.lightingModel = .constant
        screen.diffuse.contents = NSColor.black
        screen.diffuse.minificationFilter = .linear
        screen.diffuse.magnificationFilter = .linear
        screen.diffuse.mipFilter = .linear
        screen.diffuse.maxAnisotropy = 8
        display.materials = [screen]
        let displayNode = SCNNode(geometry: display)
        displayNode.position = SCNVector3(0, spec.chin + spec.screen.height / 2, 0.03)
        lidPivot.addChildNode(displayNode)

        // Glass reflections over the display.
        let sheen = SCNPlane(width: w - 2, height: spec.lid.height - 2)
        sheen.cornerRadius = spec.cornerRadius - 1
        let sheenMaterial = SCNMaterial()
        sheenMaterial.lightingModel = .physicallyBased
        sheenMaterial.diffuse.contents = NSColor.black
        sheenMaterial.roughness.contents = 0.12
        sheenMaterial.blendMode = .add
        sheenMaterial.writesToDepthBuffer = false
        sheen.materials = [sheenMaterial]
        let sheenNode = SCNNode(geometry: sheen)
        sheenNode.position = SCNVector3(0, spec.lid.height / 2, 0.08)
        sheenNode.opacity = 0.45
        lidPivot.addChildNode(sheenNode)

        // Camera notch.
        let notchHeight: CGFloat = spec.topBezel + 3.2
        let notch = SCNPlane(width: 31, height: notchHeight)
        notch.cornerRadius = 2.6
        let notchMaterial = SCNMaterial()
        notchMaterial.lightingModel = .constant
        notchMaterial.diffuse.contents = NSColor(white: 0.01, alpha: 1)
        notch.materials = [notchMaterial]
        let notchNode = SCNNode(geometry: notch)
        notchNode.position = SCNVector3(0, spec.lid.height - notchHeight / 2, 0.06)
        lidPivot.addChildNode(notchNode)

        // Centre everything on the display.
        let center = lidPivot.convertPosition(displayNode.position, to: model)
        model.position = SCNVector3(-center.x, -center.y, -center.z)
        let root = SCNNode()
        root.addChildNode(model)
        return (root, screen, displayNode)
    }

    /// Keyboard deck texture: dark keys in a well.
    private static func keyboardImage(finish: LaptopFinish) -> CGImage? {
        let w = 1400, h = 560
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: RenderCore.sRGB,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(finish.body.mixed(with: .black, 0.25).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let rows: [[CGFloat]] = [
            Array(repeating: 1, count: 14),
            [1.4] + Array(repeating: 1, count: 12) + [1.4],
            [1.7] + Array(repeating: 1, count: 11) + [1.8],
            [2.2] + Array(repeating: 1, count: 10) + [2.3],
            [1, 1, 1, 1.25, 5.6, 1.25, 1, 2.9],
        ]
        let margin: CGFloat = 26, gap: CGFloat = 9
        let rowH = (CGFloat(h) - margin * 2 - gap * CGFloat(rows.count + 1)) / CGFloat(rows.count + 1)
        ctx.setFillColor(finish.keys.cgColor)
        // Function row (half height) at the top of the texture (= towards the hinge).
        var y = CGFloat(h) - margin - rowH * 0.6
        let fnWidth = (CGFloat(w) - margin * 2 - gap * 15) / 16
        for i in 0..<16 {
            let rect = CGRect(x: margin + CGFloat(i) * (fnWidth + gap), y: y, width: fnWidth, height: rowH * 0.6)
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil))
        }
        ctx.fillPath()
        for row in rows {
            y -= rowH + gap
            let units = row.reduce(0, +)
            let unit = (CGFloat(w) - margin * 2 - gap * CGFloat(row.count - 1)) / units
            var x = margin
            for size in row {
                let rect = CGRect(x: x, y: y, width: unit * size, height: rowH)
                ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 7, cornerHeight: 7, transform: nil))
                x += unit * size + gap
            }
            ctx.fillPath()
        }
        return ctx.makeImage()
    }
}
