import AppKit
import CoreGraphics

// Renders the Pop Sidekick app icon at a given pixel size.
// Design: a macOS "squircle" tile with a blue→purple gradient, a white rounded
// popup/speech bubble (evoking PopClip) and a four-point AI sparkle.
func render(size: CGFloat) -> CGImage {
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: Int(size), height: Int(size),
                        bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high

    let S = size
    // macOS icons leave a transparent margin; the tile occupies ~82% centred.
    let inset = S * 0.09
    let rect = CGRect(x: inset, y: inset, width: S - inset * 2, height: S - inset * 2)
    let corner = rect.width * 0.2237 // Apple's continuous-corner ratio

    func squirclePath(_ r: CGRect, _ c: CGFloat) -> CGPath {
        CGPath(roundedRect: r, cornerWidth: c, cornerHeight: c, transform: nil)
    }

    // Subtle drop shadow under the tile.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -S * 0.012),
                  blur: S * 0.03,
                  color: NSColor(white: 0, alpha: 0.28).cgColor)
    ctx.addPath(squirclePath(rect, corner))
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // Gradient fill (top-left indigo → bottom-right violet/pink).
    ctx.saveGState()
    ctx.addPath(squirclePath(rect, corner))
    ctx.clip()
    let colors = [
        NSColor(calibratedRed: 0.29, green: 0.44, blue: 0.98, alpha: 1).cgColor, // blue
        NSColor(calibratedRed: 0.51, green: 0.31, blue: 0.94, alpha: 1).cgColor, // indigo
        NSColor(calibratedRed: 0.85, green: 0.33, blue: 0.86, alpha: 1).cgColor  // magenta
    ] as CFArray
    let grad = CGGradient(colorsSpace: cs, colors: colors, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(grad,
                           start: CGPoint(x: rect.minX, y: rect.maxY),
                           end: CGPoint(x: rect.maxX, y: rect.minY),
                           options: [])
    // Soft top highlight for a glassy feel.
    let hi = CGGradient(colorsSpace: cs, colors: [
        NSColor(white: 1, alpha: 0.22).cgColor,
        NSColor(white: 1, alpha: 0).cgColor
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(hi,
                           start: CGPoint(x: rect.midX, y: rect.maxY),
                           end: CGPoint(x: rect.midX, y: rect.midY),
                           options: [])
    ctx.restoreGState()

    // White popup bubble (rounded rect with a small tail at the bottom).
    let bw = rect.width * 0.52
    let bh = rect.height * 0.40
    let bx = rect.midX - bw / 2
    let by = rect.midY - bh / 2 + rect.height * 0.045
    let bubble = CGRect(x: bx, y: by, width: bw, height: bh)
    let bc = bh * 0.30

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -S * 0.006),
                  blur: S * 0.02,
                  color: NSColor(white: 0, alpha: 0.22).cgColor)
    let bubblePath = CGMutablePath()
    bubblePath.addPath(squirclePath(bubble, bc))
    // Downward tail.
    let tw = bw * 0.16
    let ty = by
    let tailMidX = rect.midX - bw * 0.12
    bubblePath.move(to: CGPoint(x: tailMidX - tw / 2, y: ty + 2))
    bubblePath.addLine(to: CGPoint(x: tailMidX, y: ty - bh * 0.26))
    bubblePath.addLine(to: CGPoint(x: tailMidX + tw / 2, y: ty + 2))
    bubblePath.closeSubpath()
    ctx.addPath(bubblePath)
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // Two action "dots" inside the bubble (PopClip-style controls).
    let dotR = bh * 0.085
    let dotY = by + bh * 0.44
    let gradientDot = { (cx: CGFloat, color: NSColor) in
        ctx.setFillColor(color.cgColor)
        ctx.fillEllipse(in: CGRect(x: cx - dotR, y: dotY - dotR, width: dotR * 2, height: dotR * 2))
    }
    gradientDot(bx + bw * 0.30, NSColor(calibratedRed: 0.29, green: 0.44, blue: 0.98, alpha: 1))
    gradientDot(bx + bw * 0.52, NSColor(calibratedRed: 0.51, green: 0.31, blue: 0.94, alpha: 1))
    gradientDot(bx + bw * 0.74, NSColor(calibratedRed: 0.85, green: 0.33, blue: 0.86, alpha: 1))

    // Four-point AI sparkle at the top-right of the bubble.
    func sparkle(center: CGPoint, radius: CGFloat, color: NSColor) {
        let p = CGMutablePath()
        let waist = radius * 0.30
        p.move(to: CGPoint(x: center.x, y: center.y + radius))
        p.addQuadCurve(to: CGPoint(x: center.x + radius, y: center.y),
                       control: CGPoint(x: center.x + waist, y: center.y + waist))
        p.addQuadCurve(to: CGPoint(x: center.x, y: center.y - radius),
                       control: CGPoint(x: center.x + waist, y: center.y - waist))
        p.addQuadCurve(to: CGPoint(x: center.x - radius, y: center.y),
                       control: CGPoint(x: center.x - waist, y: center.y - waist))
        p.addQuadCurve(to: CGPoint(x: center.x, y: center.y + radius),
                       control: CGPoint(x: center.x - waist, y: center.y + waist))
        p.closeSubpath()
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: S * 0.015, color: color.withAlphaComponent(0.6).cgColor)
        ctx.addPath(p)
        ctx.setFillColor(color.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
    }
    sparkle(center: CGPoint(x: bx + bw * 0.98, y: by + bh * 0.92),
            radius: bh * 0.26, color: NSColor(calibratedRed: 1.0, green: 0.82, blue: 0.25, alpha: 1))
    sparkle(center: CGPoint(x: bx + bw * 1.12, y: by + bh * 0.62),
            radius: bh * 0.12, color: NSColor(calibratedRed: 1.0, green: 0.82, blue: 0.25, alpha: 1))

    return ctx.makeImage()!
}

// Emit the required iconset sizes.
let sizes: [(String, CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

for (name, px) in sizes {
    let img = render(size: px)
    let rep = NSBitmapImageRep(cgImage: img)
    rep.size = NSSize(width: px, height: px)
    let data = rep.representation(using: .png, properties: [:])!
    let url = URL(fileURLWithPath: "\(outDir)/\(name).png")
    try! data.write(to: url)
    print("wrote \(url.lastPathComponent)")
}
