// Draws the AppXMotion app icon (1024×1024 PNG). Usage: swift scripts/make-icon.swift out.png
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

// Background tile (macOS icon grid: 824pt tile centred in 1024).
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: color(0x000000, 0.28))
ctx.addPath(tilePath); ctx.setFillColor(color(0xFFFFFF)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(tilePath); ctx.clip()
let bg = CGGradient(colorsSpace: space, colors: [color(0xFBC2EB), color(0xA6C1EE), color(0x667EEA)] as CFArray, locations: [0, 0.55, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: tile.minX, y: tile.maxY), end: CGPoint(x: tile.maxX, y: tile.minY), options: [])
ctx.restoreGState()

// Phone with shadow.
let phone = CGRect(x: 512 - 165, y: 512 - 330, width: 330, height: 660)
let phonePath = CGPath(roundedRect: phone, cornerWidth: 62, cornerHeight: 62, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -40), blur: 70, color: color(0x1B1446, 0.45))
ctx.addPath(phonePath); ctx.setFillColor(color(0x1C1C1E)); ctx.fillPath()
ctx.restoreGState()
let screen = phone.insetBy(dx: 18, dy: 18)
let screenPath = CGPath(roundedRect: screen, cornerWidth: 46, cornerHeight: 46, transform: nil)
ctx.saveGState()
ctx.addPath(screenPath); ctx.clip()
let sg = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF), color(0xF1F3FA)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(sg, start: CGPoint(x: 0, y: screen.maxY), end: CGPoint(x: 0, y: screen.minY), options: [])
// App UI hints: header card + rows.
ctx.setFillColor(color(0x667EEA)); ctx.fill(CGRect(x: screen.minX + 28, y: screen.maxY - 230, width: screen.width - 56, height: 130).insetBy(dx: 0, dy: 0))
for i in 0..<4 {
    let y = screen.maxY - 300 - CGFloat(i) * 70
    ctx.setFillColor(color(0xD9DDEA)); ctx.fill(CGRect(x: screen.minX + 28, y: y, width: 44, height: 44))
    ctx.setFillColor(color(0xE4E7F0)); ctx.fill(CGRect(x: screen.minX + 88, y: y + 10, width: screen.width - 140 - CGFloat(i % 2) * 50, height: 22))
}
ctx.restoreGState()
// Camera hole.
ctx.setFillColor(color(0x000000)); ctx.fillEllipse(in: CGRect(x: 512 - 11, y: screen.maxY - 36, width: 22, height: 22))

// Zoom lens badge.
let lens = CGRect(x: 560, y: 250, width: 230, height: 230)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: color(0x000000, 0.3))
ctx.setFillColor(color(0xFFFFFF)); ctx.fillEllipse(in: lens)
ctx.restoreGState()
ctx.setStrokeColor(color(0x5B5FE0)); ctx.setLineWidth(22)
ctx.strokeEllipse(in: lens.insetBy(dx: 40, dy: 40))
ctx.setLineCap(.round); ctx.setLineWidth(26)
ctx.move(to: CGPoint(x: lens.midX + 52, y: lens.midY - 52)); ctx.addLine(to: CGPoint(x: lens.maxX + 10, y: lens.minY - 10)); ctx.strokePath()
ctx.setLineWidth(16)
ctx.move(to: CGPoint(x: lens.midX - 30, y: lens.midY)); ctx.addLine(to: CGPoint(x: lens.midX + 30, y: lens.midY))
ctx.move(to: CGPoint(x: lens.midX, y: lens.midY - 30)); ctx.addLine(to: CGPoint(x: lens.midX, y: lens.midY + 30)); ctx.strokePath()

let image = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print("wrote \(out)")
