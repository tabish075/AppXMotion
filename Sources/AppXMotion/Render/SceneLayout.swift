import AppKit

/// Where one phone (and its screen) sits on the canvas. Top-left origin, canvas pixels.
struct DeviceGeometry {
    var body: CGRect
    var screen: CGRect
    var screenRadius: CGFloat
    var bodyRadius: CGFloat
    var rim: CGFloat
    var landscape: Bool
    var camera: CGPoint
    var cameraRadius: CGFloat
    var buttons: [CGRect]
    /// Browser frames: the page's top corners meet the address bar, so only the bottom ones are rounded.
    var squareTop = false
    /// Browser frames: the drawn title/address bar.
    var chromeBar: CGRect?
}

struct TextBlock {
    var text: String
    var rect: CGRect
    var font: NSFont
    var alpha: CGFloat
    var kern: CGFloat
}

enum Fonts {
    static func title(_ size: CGFloat) -> NSFont { NSFont.systemFont(ofSize: size, weight: .bold) }
    static func subtitle(_ size: CGFloat) -> NSFont { NSFont.systemFont(ofSize: size, weight: .medium) }
    static func label(_ size: CGFloat) -> NSFont { NSFont.systemFont(ofSize: size, weight: .semibold) }

    static func attributed(_ block: TextBlock, color: RGBAColor) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        return NSAttributedString(string: block.text, attributes: [
            .font: block.font,
            .foregroundColor: color.alpha(Double(block.alpha) * color.a).nsColor,
            .paragraphStyle: paragraph,
            .kern: block.kern,
        ])
    }

    static func measure(_ text: String, font: NSFont, width: CGFloat, maxLines: Int, kern: CGFloat = 0) -> CGFloat {
        let block = TextBlock(text: text, rect: .zero, font: font, alpha: 1, kern: kern)
        let bounds = attributed(block, color: .black).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        return min(ceil(bounds.height), lineHeight * CGFloat(maxLines))
    }
}

/// Frame thickness around the screen for each style, as fractions of a reference length:
/// the screen's short side for phones, the screen's width for web frames.
private struct FrameMetrics {
    var top: CGFloat = 0
    var side: CGFloat = 0
    var bottom: CGFloat = 0
    var rim: CGFloat = 0
    var screenRadius: CGFloat = 0
    var bodyRadius: CGFloat?
    var refIsWidth = false
    /// 3D models have a fixed screen shape; recordings are fitted to it.
    var fixedAspect: CGFloat?
    var squareTop = false

    init(_ device: DeviceSettings) {
        let round = CGFloat(device.roundness)
        switch device.style {
        case .galaxy3D:
            let spec = PhoneSpec.galaxyUltra.withRoundness(round)
            let bezel = (spec.body.width - spec.screen.width) / 2 / spec.screen.width
            (top, side, bottom) = (bezel, bezel, bezel)
            screenRadius = spec.screenRadius / spec.screen.width
            bodyRadius = spec.bodyRadius / spec.screen.width
            fixedAspect = spec.screen.width / spec.screen.height
        case .phone:
            (top, side, bottom, rim) = (0.05, 0.05, 0.05, 0.016)
            screenRadius = 0.09 * round
        case .minimal:
            (top, side, bottom, rim) = (0.026, 0.026, 0.026, 0.008)
            screenRadius = 0.09 * round
        case .screenOnly:
            screenRadius = 0.09 * round
        case .browser:
            top = 0.046
            screenRadius = 0.011 * round
            bodyRadius = 0.011 * round
            refIsWidth = true
            squareTop = true
        case .window:
            screenRadius = 0.011 * round
            refIsWidth = true
        case .macbook3D:
            let spec = LaptopSpec.macbookPro
            side = (spec.lid.width - spec.screen.width) / 2 / spec.screen.width
            top = spec.topBezel / spec.screen.width
            // Chin plus room for the keyboard deck seen in perspective.
            bottom = (spec.chin + spec.lid.width * 0.24) / spec.screen.width
            screenRadius = 0.012
            refIsWidth = true
            fixedAspect = spec.screen.width / spec.screen.height
        }
    }

    /// Reference length for a screen of aspect `a`, in units of the screen height.
    func ref(_ a: CGFloat) -> CGFloat { refIsWidth ? a : min(a, 1) }
    func unitW(_ a: CGFloat) -> CGFloat { a + 2 * side * ref(a) }
    func unitH(_ a: CGFloat) -> CGFloat { 1 + (top + bottom) * ref(a) }
}

/// Positions of every device and text block on the canvas.
struct SceneLayout {
    var canvas: CGSize
    var unit: CGFloat
    var devices: [DeviceGeometry]
    var texts: [TextBlock]

    static func make(canvas: CGSize, style: StyleSettings, mode: LayoutMode, aspects rawAspects: [CGFloat]) -> SceneLayout {
        let compare = mode == .compare
        let W = canvas.width, H = canvas.height
        let u = min(W, H)
        let margin = u * 0.07
        let contentW = W - margin * 2
        let textScale = CGFloat(style.text.size)
        let metrics = FrameMetrics(style.device)
        let fallbackAspect: CGFloat = style.device.style.platform == .web ? 16.0 / 10.0 : 9.0 / 20.0
        var aspects = (rawAspects.isEmpty ? [fallbackAspect] : rawAspects).map { max(0.2, min(5, $0)) }
        if let fixed = metrics.fixedAspect { aspects = aspects.map { _ in fixed } }

        // Header text (title + subtitle).
        let title = style.text.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let subtitle = style.text.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let titleFont = Fonts.title(u * 0.058 * textScale)
        let titleKern = -titleFont.pointSize * 0.02
        let subFont = Fonts.subtitle(u * 0.032 * textScale)
        let labelFont = Fonts.label(u * 0.036 * textScale)
        let titleH = title.isEmpty ? 0 : Fonts.measure(title, font: titleFont, width: contentW, maxLines: 2, kern: titleKern)
        let subH = subtitle.isEmpty ? 0 : Fonts.measure(subtitle, font: subFont, width: contentW, maxLines: 2)
        let titleSubGap: CGFloat = (titleH > 0 && subH > 0) ? u * 0.014 : 0
        let headerH = titleH + titleSubGap + subH
        let headerGap: CGFloat = headerH > 0 ? u * 0.05 : 0

        // Labels under each device (compare mode).
        let labels = (compare && style.text.showLabels) ? [style.text.labelA, style.text.labelB] : []
        let isGrid = mode == .tour && aspects.count > 1
        let showLabels = labels.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let labelH: CGFloat = showLabels ? ceil(labelFont.ascender - labelFont.descender) : 0
        let labelGap: CGFloat = showLabels ? u * 0.035 : 0

        // Fit: every screen shares the same height `sh`.
        let n = CGFloat(aspects.count)
        let gap: CGFloat = aspects.count > 1 ? u * (isGrid ? 0.05 : 0.075) : 0
        let availH = max(10, H - margin * 2 - headerH - headerGap - labelH - labelGap)

        // Rows: 1 for single/compare; for a tour board pick the grid that makes the devices biggest.
        var rows = 1
        var sh: CGFloat = 0
        let maxA = aspects.max() ?? 0.45
        for r in 1...(isGrid ? aspects.count : 1) {
            let cols = Int(ceil(Double(aspects.count) / Double(r)))
            let byW = (contentW - gap * CGFloat(cols - 1)) / (CGFloat(cols) * metrics.unitW(maxA))
            let byH = (availH - gap * CGFloat(r - 1)) / (CGFloat(r) * metrics.unitH(maxA))
            let rowFit = isGrid ? min(byW, byH)
                : min((contentW - gap * (n - 1)) / aspects.reduce(0) { $0 + metrics.unitW($1) },
                      aspects.map { availH / metrics.unitH($0) }.min() ?? availH)
            if rowFit > sh { sh = rowFit; rows = r }
        }
        sh = max(8, sh * CGFloat(style.device.size))
        let cols = Int(ceil(Double(aspects.count) / Double(rows)))

        let sizes = aspects.map { a in CGSize(width: sh * metrics.unitW(a), height: sh * metrics.unitH(a)) }
        let rowWidths: [CGFloat] = (0..<rows).map { r in
            let items = sizes.enumerated().filter { $0.offset / cols == r }.map(\.element.width)
            return items.reduce(0, +) + gap * CGFloat(max(0, items.count - 1))
        }
        let maxH = sizes.map(\.height).max() ?? 0
        let gridH = maxH * CGFloat(rows) + gap * CGFloat(rows - 1)
        let totalH = headerH + headerGap + gridH + labelGap + labelH
        let top = max(margin * 0.5, (H - totalH) / 2)

        var texts: [TextBlock] = []
        var y = top
        if titleH > 0 {
            texts.append(TextBlock(text: title, rect: CGRect(x: margin, y: y, width: contentW, height: titleH), font: titleFont, alpha: 1, kern: titleKern))
            y += titleH + titleSubGap
        }
        if subH > 0 {
            texts.append(TextBlock(text: subtitle, rect: CGRect(x: margin, y: y, width: contentW, height: subH), font: subFont, alpha: 0.68, kern: 0))
        }

        let devicesTop = top + headerH + headerGap
        var x: CGFloat = 0
        var devices: [DeviceGeometry] = []
        for (i, a) in aspects.enumerated() {
            let size = sizes[i]
            let row = i / cols
            if i % cols == 0 { x = (W - rowWidths[row]) / 2 }
            let rowTop = devicesTop + CGFloat(row) * (maxH + gap)
            let body = CGRect(x: x, y: rowTop + (maxH - size.height) / 2, width: size.width, height: size.height)
            let m = sh * metrics.ref(a)
            let short = sh * min(a, 1)
            let screen = CGRect(x: body.minX + metrics.side * m, y: body.minY + metrics.top * m, width: sh * a, height: sh)
            let screenRadius = min(metrics.screenRadius * m, min(screen.width, screen.height) / 2)
            let landscape = a > 1
            let camera = landscape
                ? CGPoint(x: screen.minX + short * 0.05, y: screen.midY)
                : CGPoint(x: screen.midX, y: screen.minY + short * 0.05)

            var buttons: [CGRect] = []
            if style.device.style == .phone && style.device.showButtons {
                let bw = short * 0.016
                if landscape {
                    buttons.append(CGRect(x: body.minX + body.width * 0.62, y: body.minY - bw * 0.65, width: body.width * 0.07, height: bw))
                    buttons.append(CGRect(x: body.minX + body.width * 0.73, y: body.minY - bw * 0.65, width: body.width * 0.11, height: bw))
                } else {
                    buttons.append(CGRect(x: body.maxX - bw * 0.35, y: body.minY + body.height * 0.20, width: bw, height: body.height * 0.075))
                    buttons.append(CGRect(x: body.maxX - bw * 0.35, y: body.minY + body.height * 0.31, width: bw, height: body.height * 0.13))
                }
            }
            let bodyRadius = metrics.bodyRadius.map { $0 * m } ?? (screenRadius + metrics.side * m)

            devices.append(DeviceGeometry(
                body: body, screen: screen, screenRadius: screenRadius,
                bodyRadius: min(bodyRadius, min(body.width, body.height) / 2),
                rim: metrics.rim * m, landscape: landscape,
                camera: camera, cameraRadius: short * 0.017, buttons: buttons,
                squareTop: metrics.squareTop,
                chromeBar: style.device.style == .browser ? CGRect(x: body.minX, y: body.minY, width: body.width, height: metrics.top * m) : nil
            ))

            if showLabels, i < labels.count {
                let w = size.width + gap
                texts.append(TextBlock(text: labels[i], rect: CGRect(x: body.midX - w / 2, y: devicesTop + maxH + labelGap, width: w, height: labelH + 2),
                                       font: labelFont, alpha: 0.88, kern: 0))
            }
            x += size.width + gap
        }

        return SceneLayout(canvas: canvas, unit: u, devices: devices, texts: texts)
    }
}
