import AppKit
import CoreGraphics

/// Draws the static parts of a scene (background, phone bodies, shadows, text) with Core Graphics.
/// These are drawn once per style change and reused for every video frame.
enum ScenePainter {
    /// A bitmap context with a top-left origin, measured in canvas points × `scale`.
    static func makeContext(size: CGSize, scale: CGFloat) -> CGContext? {
        let width = max(1, Int((size.width * scale).rounded()))
        let height = max(1, Int((size.height * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: RenderCore.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.scaleBy(x: scale, y: scale)
        ctx.setShouldAntialias(true)
        ctx.interpolationQuality = .high
        return ctx
    }

    static func roundedPath(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
        let r = max(0, min(radius, min(rect.width, rect.height) / 2 - 0.01))
        return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
    }

    // MARK: Background

    static func background(size: CGSize, settings bg: BackgroundSettings) -> CGImage? {
        guard let ctx = makeContext(size: size, scale: 1) else { return nil }
        let rect = CGRect(origin: .zero, size: size)
        let colors = [bg.color1.cgColor, bg.color2.cgColor] as CFArray

        switch bg.style {
        case .solid, .blurredApp:
            ctx.setFillColor(bg.color1.cgColor)
            ctx.fill(rect)
        case .gradient:
            guard let gradient = CGGradient(colorsSpace: RenderCore.sRGB, colors: colors, locations: [0, 1]) else { break }
            let theta = bg.angle * .pi / 180
            let dir = CGPoint(x: sin(theta), y: -cos(theta))
            let length = abs(size.width * sin(theta)) + abs(size.height * cos(theta))
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            ctx.drawLinearGradient(gradient,
                                   start: CGPoint(x: c.x - dir.x * length / 2, y: c.y - dir.y * length / 2),
                                   end: CGPoint(x: c.x + dir.x * length / 2, y: c.y + dir.y * length / 2),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            dither(ctx)
        case .radial:
            guard let gradient = CGGradient(colorsSpace: RenderCore.sRGB, colors: colors, locations: [0, 1]) else { break }
            let c = CGPoint(x: size.width / 2, y: size.height * 0.45)
            ctx.drawRadialGradient(gradient, startCenter: c, startRadius: 0, endCenter: c,
                                   endRadius: hypot(size.width, size.height) * 0.62, options: [.drawsAfterEndLocation])
            dither(ctx)
        }
        return ctx.makeImage()
    }

    /// Adds ±1 LSB of noise so smooth gradients don't band after X's re-compression.
    private static func dither(_ ctx: CGContext) {
        guard let data = ctx.data else { return }
        let bytes = data.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * ctx.height)
        var seed: UInt32 = 0x9E3779B9
        for y in 0..<ctx.height {
            let row = bytes + y * ctx.bytesPerRow
            for x in 0..<ctx.width {
                seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5
                let delta = Int(seed % 3) - 1
                if delta == 0 { continue }
                let p = row + x * 4
                for k in 0..<3 {
                    p[k] = UInt8(clamping: Int(p[k]) + delta)
                }
            }
        }
    }

    // MARK: Phones (below the screen content)

    static func underLayer(layout: SceneLayout, style: StyleSettings, scale: CGFloat, placeholders: Set<Int>) -> CGImage? {
        guard let ctx = makeContext(size: layout.canvas, scale: scale) else { return nil }
        let frame = FrameColor.named(style.device.frameColorID)
        let u = layout.unit

        for (index, dev) in layout.devices.enumerated() where !style.device.style.is3D {
            let isScreenOnly = style.device.style == .screenOnly || style.device.style == .window
            let outline = isScreenOnly ? dev.screen : dev.body
            let outlineRadius = isScreenOnly ? dev.screenRadius : dev.bodyRadius
            let bodyPath = roundedPath(outline, outlineRadius)
            let bodyColor = isScreenOnly || dev.chromeBar != nil ? CGColor(gray: 0, alpha: 1) : frame.body.cgColor

            // Two-layer shadow: a wide ambient one plus a tight contact shadow.
            // Shadow geometry is in device pixels (not affected by the CTM), hence `* scale`.
            if style.shadow.enabled && style.shadow.strength > 0.01 {
                let strength = CGFloat(style.shadow.strength)
                let soft = CGFloat(style.shadow.softness)
                ctx.saveGState()
                ctx.setShadow(offset: CGSize(width: 0, height: -u * (0.018 + 0.03 * soft) * scale),
                              blur: u * (0.04 + 0.09 * soft) * scale,
                              color: CGColor(gray: 0, alpha: min(1, 0.30 * strength)))
                ctx.addPath(bodyPath)
                ctx.setFillColor(bodyColor)
                ctx.fillPath()
                ctx.restoreGState()

                ctx.saveGState()
                ctx.setShadow(offset: CGSize(width: 0, height: -u * (0.004 + 0.008 * soft) * scale),
                              blur: u * (0.008 + 0.016 * soft) * scale,
                              color: CGColor(gray: 0, alpha: min(1, 0.28 * strength)))
                ctx.addPath(bodyPath)
                ctx.setFillColor(bodyColor)
                ctx.fillPath()
                ctx.restoreGState()
            }

            if let bar = dev.chromeBar {
                drawBrowser(ctx, dev: dev, bar: bar, style: style, scale: scale)
            } else if !isScreenOnly {
                drawBody(ctx, dev: dev, frame: frame, unit: u, scale: scale)
            }

            // The screen itself (covered by the recording).
            ctx.addPath(dev.squareTop ? bottomRoundedPath(dev.screen, dev.screenRadius) : roundedPath(dev.screen, dev.screenRadius))
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.fillPath()

            if placeholders.contains(index) {
                drawPlaceholder(ctx, dev: dev)
            }
        }
        return ctx.makeImage()
    }

    private static func drawBody(_ ctx: CGContext, dev: DeviceGeometry, frame: FrameColor, unit u: CGFloat, scale: CGFloat) {
        let bodyPath = roundedPath(dev.body, dev.bodyRadius)

        // Side buttons sit slightly outside the body.
        for button in dev.buttons {
            ctx.addPath(roundedPath(button, min(button.width, button.height) / 2))
            ctx.setFillColor(frame.body.mixed(with: .black, 0.18).cgColor)
            ctx.fillPath()
        }

        // Metal rim.
        ctx.addPath(bodyPath)
        ctx.setFillColor(frame.body.cgColor)
        ctx.fillPath()

        // Soft sheen across the rim.
        ctx.saveGState()
        ctx.addPath(bodyPath)
        ctx.clip()
        let sheen = [RGBAColor.white.alpha(0.20).cgColor, RGBAColor.white.alpha(0).cgColor, RGBAColor.black.alpha(0.14).cgColor] as CFArray
        if let gradient = CGGradient(colorsSpace: RenderCore.sRGB, colors: sheen, locations: [0, 0.45, 1]) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: dev.body.minX, y: dev.body.minY),
                                   end: CGPoint(x: dev.body.maxX, y: dev.body.maxY), options: [])
        }
        ctx.restoreGState()

        // Highlight line along the rim.
        if dev.rim > 0 {
            let inset = dev.rim * 0.42
            ctx.addPath(roundedPath(dev.body.insetBy(dx: inset, dy: inset), dev.bodyRadius - inset))
            ctx.setStrokeColor(frame.highlight.alpha(0.55).cgColor)
            ctx.setLineWidth(max(0.6 / scale, dev.rim * 0.16))
            ctx.strokePath()
        }

        // Thin dark outline for definition on light backgrounds.
        ctx.addPath(bodyPath)
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.28))
        ctx.setLineWidth(max(0.8 / scale, u * 0.0012))
        ctx.strokePath()

        // Black glass bezel.
        let bezelRect = dev.body.insetBy(dx: dev.rim, dy: dev.rim)
        ctx.addPath(roundedPath(bezelRect, dev.bodyRadius - dev.rim))
        ctx.setFillColor(CGColor(srgbRed: 0.03, green: 0.03, blue: 0.035, alpha: 1))
        ctx.fillPath()
    }

    static func bottomRoundedPath(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
        let r = max(0, min(radius, min(rect.width, rect.height) / 2 - 0.01))
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY), radius: r)
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.minY), radius: r)
        path.closeSubpath()
        return path
    }

    /// A clean, generic browser window: traffic lights and a centred address bar.
    private static func drawBrowser(_ ctx: CGContext, dev: DeviceGeometry, bar: CGRect, style: StyleSettings, scale: CGFloat) {
        let dark = style.device.chromeTheme == .dark
        let body = roundedPath(dev.body, dev.bodyRadius)
        ctx.addPath(body)
        ctx.setFillColor(dark ? CGColor(srgbRed: 0.16, green: 0.16, blue: 0.18, alpha: 1) : CGColor(srgbRed: 0.955, green: 0.955, blue: 0.965, alpha: 1))
        ctx.fillPath()

        // Traffic lights.
        let r = bar.height * 0.135
        let colors: [UInt32] = [0xFF5F57, 0xFEBC2E, 0x28C840]
        for (i, hex) in colors.enumerated() {
            let c = CGPoint(x: bar.minX + bar.height * 0.6 + CGFloat(i) * r * 3.3, y: bar.midY)
            ctx.setFillColor(RGBAColor(hex: hex).cgColor)
            ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.12))
            ctx.setLineWidth(max(0.5 / scale, r * 0.08))
            ctx.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        }

        // Address bar.
        let pillW = min(bar.width * 0.46, bar.width - bar.height * 6)
        let pill = CGRect(x: bar.midX - pillW / 2, y: bar.minY + bar.height * 0.2, width: pillW, height: bar.height * 0.6)
        ctx.addPath(roundedPath(pill, pill.height * 0.32))
        ctx.setFillColor(dark ? CGColor(srgbRed: 0.24, green: 0.24, blue: 0.27, alpha: 1) : CGColor(gray: 1, alpha: 1))
        ctx.fillPath()
        if !dark {
            ctx.addPath(roundedPath(pill, pill.height * 0.32))
            ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.07))
            ctx.setLineWidth(max(0.5 / scale, bar.height * 0.012))
            ctx.strokePath()
        }
        let url = style.device.browserURL.trimmingCharacters(in: .whitespaces)
        let textColor = dark ? RGBAColor(hex: 0xC7C7CC) : RGBAColor(hex: 0x4A4A50)
        let font = NSFont.systemFont(ofSize: pill.height * 0.46, weight: .medium)
        let label = NSAttributedString(string: url.isEmpty ? "yourapp.com" : url, attributes: [.font: font, .foregroundColor: textColor.nsColor])
        let size = label.size()
        let lockW = pill.height * 0.42
        let total = lockW + pill.height * 0.25 + size.width
        let startX = pill.midX - total / 2
        drawText(ctx) {
            if let lock = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: pill.height * 0.36, weight: .semibold)) {
                let tinted = NSImage(size: lock.size, flipped: false) { rect in
                    lock.draw(in: rect)
                    textColor.alpha(0.8).nsColor.set()
                    rect.fill(using: .sourceAtop)
                    return true
                }
                let h = pill.height * 0.42, w = h * lock.size.width / max(1, lock.size.height)
                tinted.draw(in: CGRect(x: startX, y: pill.midY - h / 2, width: w, height: h))
            }
            label.draw(at: CGPoint(x: startX + lockW + pill.height * 0.25, y: pill.midY - size.height / 2))
        }

        // Separator under the toolbar.
        ctx.setFillColor(dark ? CGColor(gray: 0, alpha: 0.5) : CGColor(gray: 0, alpha: 0.09))
        ctx.fill(CGRect(x: bar.minX, y: bar.maxY - max(0.6 / scale, bar.height * 0.012), width: bar.width, height: max(0.6 / scale, bar.height * 0.012)))

        // Thin outline for definition.
        ctx.addPath(body)
        ctx.setStrokeColor(CGColor(gray: 0, alpha: dark ? 0.4 : 0.12))
        ctx.setLineWidth(max(0.6 / scale, bar.height * 0.012))
        ctx.strokePath()
    }

    private static func drawPlaceholder(_ ctx: CGContext, dev: DeviceGeometry) {
        ctx.addPath(roundedPath(dev.screen, dev.screenRadius))
        ctx.setFillColor(CGColor(srgbRed: 0.13, green: 0.13, blue: 0.15, alpha: 1))
        ctx.fillPath()

        let size = min(dev.screen.width, dev.screen.height) * 0.07
        let block = TextBlock(text: "Drop a second\nrecording here", rect: .zero, font: Fonts.label(size), alpha: 0.55, kern: 0)
        let text = Fonts.attributed(block, color: .white)
        let bounds = text.boundingRect(with: CGSize(width: dev.screen.width * 0.9, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin])
        let rect = CGRect(x: dev.screen.midX - dev.screen.width * 0.45, y: dev.screen.midY - bounds.height / 2,
                          width: dev.screen.width * 0.9, height: bounds.height + 2)
        drawText(ctx) { text.draw(with: rect, options: [.usesLineFragmentOrigin]) }
    }

    // MARK: Above the screen content

    static func overLayer(layout: SceneLayout, style: StyleSettings, scale: CGFloat) -> CGImage? {
        guard let ctx = makeContext(size: layout.canvas, scale: scale) else { return nil }

        if (style.device.style == .phone || style.device.style == .minimal) && style.device.showCamera {
            for dev in layout.devices {
                let r = dev.cameraRadius
                let c = dev.camera
                ctx.setFillColor(CGColor(gray: 0, alpha: 1))
                ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
                ctx.setStrokeColor(CGColor(gray: 0.16, alpha: 1))
                ctx.setLineWidth(r * 0.22)
                ctx.strokeEllipse(in: CGRect(x: c.x - r * 0.62, y: c.y - r * 0.62, width: r * 1.24, height: r * 1.24))
                ctx.setFillColor(CGColor(srgbRed: 0.28, green: 0.33, blue: 0.5, alpha: 0.75))
                let h = r * 0.26
                ctx.fillEllipse(in: CGRect(x: c.x - r * 0.38 - h, y: c.y - r * 0.38 - h, width: h * 2, height: h * 2))
            }
        }

        let color = style.resolvedTextColor
        drawText(ctx) {
            for block in layout.texts {
                Fonts.attributed(block, color: color)
                    .draw(with: block.rect, options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine])
            }
        }
        return ctx.makeImage()
    }

    private static func drawText(_ ctx: CGContext, _ body: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        body()
        NSGraphicsContext.restoreGraphicsState()
    }
}
