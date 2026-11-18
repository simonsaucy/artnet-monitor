import AppKit
import CoreGraphics
import Foundation

// Cueline mark: four pill bars, one green, on a near-black squircle.
func render(size: Int, to url: URL) {
    let s = CGFloat(size)
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: size, height: size,
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
    ctx.interpolationQuality = .high
    ctx.setAllowsAntialiasing(true)

    // macOS icon grid: artwork sits in ~82% of the canvas.
    let inset = s * 0.09
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = rect.width * 0.2237   // Big Sur squircle-ish corner
    let body = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Soft drop shadow, like other macOS icons.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012),
                  blur: s * 0.035,
                  color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.55))
    ctx.addPath(body)
    ctx.setFillColor(CGColor(red: 0.055, green: 0.055, blue: 0.06, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    // Subtle top-down sheen.
    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    let colors = [CGColor(red: 0.149, green: 0.149, blue: 0.161, alpha: 1),   // #262629
                  CGColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1)] as CFArray
    if let gradient = CGGradient(colorsSpace: cs, colors: colors, locations: [0, 1]) {
        ctx.drawLinearGradient(gradient,
                               start: CGPoint(x: 0, y: rect.maxY),
                               end: CGPoint(x: 0, y: rect.minY),
                               options: [])
    }
    // Hairline rim.
    ctx.addPath(body)
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.1))
    ctx.setLineWidth(max(1, s * 0.004))
    ctx.strokePath()
    ctx.restoreGState()

    // Four bars: 18 x 2.6 with 1.9 gaps in the 18-wide logo, last one 12 wide.
    let barAreaWidth = rect.width * 0.58
    let unit = barAreaWidth / 18.0
    let barHeight = unit * 2.6
    let gap = unit * 1.9
    let totalHeight = barHeight * 4 + gap * 3
    let left = rect.midX - barAreaWidth / 2
    var y = rect.midY + totalHeight / 2 - barHeight

    let grey = CGColor(red: 0.282, green: 0.282, blue: 0.290, alpha: 1)      // #48484a
    let green = CGColor(red: 0.188, green: 0.820, blue: 0.345, alpha: 1)     // #30d158

    let widths: [CGFloat] = [18, 18, 18, 12]
    let fills = [grey, green, grey, grey]
    for i in 0..<4 {
        let w = widths[i] * unit
        let bar = CGRect(x: left, y: y, width: w, height: barHeight)
        let path = CGPath(roundedRect: bar, cornerWidth: barHeight / 2,
                          cornerHeight: barHeight / 2, transform: nil)
        if i == 1 {
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: s * 0.03,
                          color: CGColor(red: 0.188, green: 0.820, blue: 0.345, alpha: 0.7))
            ctx.addPath(path); ctx.setFillColor(fills[i]); ctx.fillPath()
            ctx.restoreGState()
        } else {
            ctx.addPath(path); ctx.setFillColor(fills[i]); ctx.fillPath()
        }
        y -= barHeight + gap
    }

    guard let image = ctx.makeImage() else { return }
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: size, height: size)
    guard let data = rep.representation(using: .png, properties: [:]) else { return }
    try? data.write(to: url)
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
for size in [16, 32, 64, 128, 256, 512, 1024] {
    render(size: size, to: out.appendingPathComponent("icon_\(size).png"))
}
print("rendered")
