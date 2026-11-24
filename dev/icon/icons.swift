// Draws the app icon options (A clay bot, B bubble bot, C bot team — C is the app icon).
// Run: swift dev/icon/icons.swift <folder>  → A-clay.png, B-bubble.png, C-team.png, preview.png (1024×1024, no alpha)

import AppKit

let S: CGFloat = 1024
let out = CommandLine.arguments[1]
func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
}

func render(_ name: String, _ draw: (CGContext) -> Void) -> CGImage {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.translateBy(x: 0, y: S); ctx.scaleBy(x: 1, y: -1) // top-left origin
    draw(ctx)
    let img = ctx.makeImage()!
    let rep = NSBitmapImageRep(cgImage: img)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
    return img
}

func background(_ c: CGContext, _ top: CGColor, _ bottom: CGColor) {
    let g = CGGradient(colorsSpace: nil, colors: [top, bottom] as CFArray, locations: [0, 1])!
    c.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: S), options: [])
}

/// Soft clay blob: a superellipse-ish body with a gentle top highlight and a ground shadow.
/// Superellipse (squircle-ish, n = 2.6): rounder than a rounded rect, no flat spots.
func squircle(_ rect: CGRect, n: CGFloat = 2.25) -> CGPath {
    let path = CGMutablePath()
    let steps = 240
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = rect.midX + rect.width / 2 * (ct >= 0 ? 1 : -1) * pow(abs(ct), 2 / n)
        let y = rect.midY + rect.height / 2 * (st >= 0 ? 1 : -1) * pow(abs(st), 2 / n)
        i == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
    }
    path.closeSubpath()
    return path
}

func blob(_ c: CGContext, rect: CGRect, fill: CGColor, shade: CGColor) {
    let path = squircle(rect)
    // ground shadow
    c.saveGState()
    c.setFillColor(rgb(0, 20, 80, 0.22))
    c.fillEllipse(in: CGRect(x: rect.midX - rect.width * 0.36, y: rect.maxY - rect.height * 0.02, width: rect.width * 0.72, height: rect.height * 0.12))
    c.restoreGState()
    // body with vertical shading
    c.saveGState()
    c.addPath(path); c.clip()
    let g = CGGradient(colorsSpace: nil, colors: [fill, shade] as CFArray, locations: [0.35, 1])!
    c.drawLinearGradient(g, start: CGPoint(x: 0, y: rect.minY), end: CGPoint(x: 0, y: rect.maxY), options: [])
    // highlight
    c.setFillColor(rgb(255, 255, 255, 0.55))
    c.fillEllipse(in: CGRect(x: rect.minX + rect.width * 0.2, y: rect.minY + rect.height * 0.1, width: rect.width * 0.26, height: rect.height * 0.12))
    c.restoreGState()
}

func eyes(_ c: CGContext, center: CGPoint, gap: CGFloat, w: CGFloat, h: CGFloat, color: CGColor) {
    c.setFillColor(color)
    for dx in [-gap / 2, gap / 2] {
        let r = CGRect(x: center.x + dx - w / 2, y: center.y - h / 2, width: w, height: h)
        c.addPath(CGPath(roundedRect: r, cornerWidth: w / 2, cornerHeight: w / 2, transform: nil)); c.fillPath()
    }
}

let blueTop = rgb(0x4A, 0x82, 0xFF), blueBottom = rgb(0x24, 0x56, 0xE8)

// A: the clay bot — same eyes-only face as the bots in the app.
let a = render("A-clay") { c in
    background(c, blueTop, blueBottom)
    let body = CGRect(x: 232, y: 250, width: 560, height: 500)
    blob(c, rect: body, fill: rgb(255, 255, 255), shade: rgb(214, 226, 255))
    eyes(c, center: CGPoint(x: S / 2, y: 505), gap: 170, w: 64, h: 112, color: rgb(0x1B, 0x2A, 0x4A))
}

// B: a chat bubble that is also the bot (talk to it) — tail bottom-left.
let b = render("B-bubble") { c in
    background(c, blueTop, blueBottom)
    let r = CGRect(x: 212, y: 262, width: 600, height: 440)
    let tail = CGMutablePath()
    tail.move(to: CGPoint(x: 290, y: 600))
    tail.addCurve(to: CGPoint(x: 230, y: 800), control1: CGPoint(x: 300, y: 700), control2: CGPoint(x: 280, y: 770))
    tail.addCurve(to: CGPoint(x: 460, y: 660), control1: CGPoint(x: 330, y: 790), control2: CGPoint(x: 410, y: 740))
    tail.closeSubpath()
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: 18), blur: 30, color: rgb(0, 20, 80, 0.25))
    c.beginTransparencyLayer(auxiliaryInfo: nil)
    c.setFillColor(rgb(255, 255, 255))
    c.addPath(squircle(r, n: 2.8)); c.fillPath()
    c.addPath(tail); c.fillPath()
    c.endTransparencyLayer()
    c.restoreGState()
    eyes(c, center: CGPoint(x: S / 2, y: 482), gap: 170, w: 60, h: 104, color: rgb(0x1B, 0x2A, 0x4A))
}

// C: a small team — one lead in front, two staff behind (bots that work together).
let cImg = render("C-team") { c in
    background(c, blueTop, blueBottom)
    blob(c, rect: CGRect(x: 150, y: 330, width: 330, height: 300), fill: rgb(0xBF, 0xF0, 0xD6), shade: rgb(0x8F, 0xD9, 0xB4))
    eyes(c, center: CGPoint(x: 315, y: 480), gap: 96, w: 38, h: 66, color: rgb(0x1B, 0x2A, 0x4A, 0.85))
    blob(c, rect: CGRect(x: 544, y: 330, width: 330, height: 300), fill: rgb(0xFF, 0xD9, 0xB0), shade: rgb(0xF5, 0xB8, 0x80))
    eyes(c, center: CGPoint(x: 709, y: 480), gap: 96, w: 38, h: 66, color: rgb(0x1B, 0x2A, 0x4A, 0.85))
    blob(c, rect: CGRect(x: 292, y: 420, width: 440, height: 400), fill: rgb(255, 255, 255), shade: rgb(214, 226, 255))
    eyes(c, center: CGPoint(x: S / 2, y: 620), gap: 130, w: 50, h: 88, color: rgb(0x1B, 0x2A, 0x4A))
}

// Preview: the three as home-screen icons side by side.
let W: CGFloat = 1500, H: CGFloat = 620
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let p = CGContext(data: nil, width: Int(W), height: Int(H), bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
p.setFillColor(rgb(242, 242, 247)); p.fill(CGRect(x: 0, y: 0, width: W, height: H))
for (i, img) in [a, b, cImg].enumerated() {
    let r = CGRect(x: 90 + CGFloat(i) * 470, y: 120, width: 380, height: 380)
    p.saveGState()
    p.addPath(CGPath(roundedRect: r, cornerWidth: 86, cornerHeight: 86, transform: nil)); p.clip()
    p.draw(img, in: r)
    p.restoreGState()
    let label = ["A", "B", "C"][i] as NSString
    NSGraphicsContext.current = NSGraphicsContext(cgContext: p, flipped: false)
    label.draw(at: CGPoint(x: r.midX - 14, y: 40), withAttributes: [.font: NSFont.systemFont(ofSize: 48, weight: .semibold), .foregroundColor: NSColor.darkGray])
}
try! NSBitmapImageRep(cgImage: p.makeImage()!).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/preview.png"))
print("ok")
