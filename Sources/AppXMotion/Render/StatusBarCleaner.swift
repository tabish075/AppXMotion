import AppKit
import CoreImage

/// Replaces a phone recording's status bar with a clean one: 9:41, full signal, Wi-Fi and battery,
/// no notification icons. Works on any phone (Samsung ignores Android's own "demo mode"), and on old recordings too.
/// The bar's background is sampled from the app just below it, every frame, so it blends in (light and dark).
final class StatusBarCleaner: @unchecked Sendable {
    /// Status bar height as a fraction of the screen height (≈ 24–30 dp on current phones).
    static let heightFraction: CGFloat = 0.037

    private let lock = NSLock()
    private var icons: [String: CIImage] = [:]

    func apply(_ frame: CIImage) -> CIImage {
        let e = frame.extent
        // Only portrait phone screens have a status bar along the top edge.
        guard e.height > e.width, e.width > 100 else { return frame }
        let band = (e.height * Self.heightFraction).rounded()
        let bandRect = CGRect(x: e.minX, y: e.maxY - band, width: e.width, height: band)

        // Sample a thin strip just below the status bar for the background colour.
        let strip = max(2, (band * 0.1).rounded())
        let sampleRect = CGRect(x: e.minX + e.width * 0.08, y: e.maxY - band - strip * 1.5, width: e.width * 0.84, height: strip)
        let average = frame.cropped(to: sampleRect)
            .applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: sampleRect)])
        var pixel = [UInt8](repeating: 0, count: 4)
        RenderCore.context.render(average, toBitmap: &pixel, rowBytes: 4,
                                  bounds: CGRect(x: average.extent.minX, y: average.extent.minY, width: 1, height: 1),
                                  format: .RGBA8, colorSpace: RenderCore.sRGB)
        let color = RGBAColor(Double(pixel[0]) / 255, Double(pixel[1]) / 255, Double(pixel[2]) / 255)
        let fill = CIImage(color: CIColor(red: CGFloat(color.r), green: CGFloat(color.g), blue: CGFloat(color.b))).cropped(to: bandRect)

        let lightIcons = color.luminance < 0.45
        guard let iconLayer = iconImage(width: e.width, height: band, light: lightIcons) else { return fill.composited(over: frame) }
        let placed = iconLayer.transformed(by: CGAffineTransform(translationX: e.minX, y: e.maxY - band))
        return placed.composited(over: fill).composited(over: frame)
    }

    /// The clock and status icons, drawn once per size and colour.
    private func iconImage(width: CGFloat, height: CGFloat, light: Bool) -> CIImage? {
        let key = "\(Int(width))x\(Int(height))-\(light)"
        lock.lock()
        if let cached = icons[key] { lock.unlock(); return cached }
        lock.unlock()

        let w = Int(width), h = Int(height)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: RenderCore.sRGB,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: height)
        ctx.scaleBy(x: 1, y: -1)
        let ink = light ? RGBAColor.white : RGBAColor(hex: 0x1A1A1A)
        let mid = height / 2
        let unit = height * 0.30

        // Clock on the left, as on Android.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        let font = NSFont.systemFont(ofSize: height * 0.40, weight: .semibold)
        let clock = NSAttributedString(string: "9:41", attributes: [.font: font, .foregroundColor: ink.nsColor])
        let size = clock.size()
        clock.draw(at: CGPoint(x: width * 0.062, y: mid - size.height / 2))
        NSGraphicsContext.restoreGraphicsState()

        ctx.setFillColor(ink.cgColor)
        ctx.setStrokeColor(ink.cgColor)
        var x = width * (1 - 0.062)

        // Battery (horizontal, full).
        let bw = unit * 1.95, bh = unit * 1.0
        x -= bw
        let body = CGRect(x: x, y: mid - bh / 2, width: bw - unit * 0.14, height: bh)
        ctx.setLineWidth(max(1, unit * 0.11))
        ctx.addPath(CGPath(roundedRect: body, cornerWidth: bh * 0.28, cornerHeight: bh * 0.28, transform: nil))
        ctx.strokePath()
        let inset = unit * 0.17
        ctx.addPath(CGPath(roundedRect: body.insetBy(dx: inset, dy: inset), cornerWidth: bh * 0.14, cornerHeight: bh * 0.14, transform: nil))
        ctx.fillPath()
        ctx.fill(CGRect(x: body.maxX + unit * 0.04, y: mid - bh * 0.2, width: unit * 0.12, height: bh * 0.4))
        x -= unit * 0.75

        // Signal: a filled wedge.
        let sw = unit * 1.35
        ctx.beginPath()
        ctx.move(to: CGPoint(x: x, y: mid + unit * 0.68))
        ctx.addLine(to: CGPoint(x: x, y: mid - unit * 0.68))
        ctx.addLine(to: CGPoint(x: x - sw, y: mid + unit * 0.68))
        ctx.closePath()
        ctx.fillPath()
        x -= sw + unit * 0.7

        // Wi-Fi: a filled fan pointing down.
        let r = unit * 1.05
        let apex = CGPoint(x: x - r * 0.72, y: mid + unit * 0.62)
        ctx.beginPath()
        ctx.move(to: apex)
        ctx.addArc(center: apex, radius: r * 1.38, startAngle: -.pi * 0.75, endAngle: -.pi * 0.25, clockwise: false)
        ctx.closePath()
        ctx.fillPath()

        guard let cg = ctx.makeImage() else { return nil }
        let image = CIImage(cgImage: cg)
        lock.lock(); icons[key] = image; lock.unlock()
        return image
    }
}
