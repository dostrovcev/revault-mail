// Рисует иконку приложения и собирает AppIcon.icns. Запуск: swift scripts/make_icon.swift <out_dir>
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build"
let iconset = "\(out)/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

func draw(_ size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.09
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let bg = NSBezierPath(roundedRect: rect, xRadius: s * 0.2, yRadius: s * 0.2)
    NSGradient(colors: [NSColor(red: 0.09, green: 0.09, blue: 0.13, alpha: 1), NSColor(red: 0.20, green: 0.16, blue: 0.36, alpha: 1)])!
        .draw(in: bg, angle: -60)

    // конверт
    let w = s * 0.50, h = s * 0.34
    let env = NSRect(x: (s - w) / 2, y: s * 0.30, width: w, height: h)
    NSColor.white.setStroke()
    let box = NSBezierPath(roundedRect: env, xRadius: s * 0.035, yRadius: s * 0.035)
    box.lineWidth = s * 0.035
    box.stroke()
    let flap = NSBezierPath()
    flap.move(to: NSPoint(x: env.minX + s * 0.02, y: env.maxY - s * 0.02))
    flap.line(to: NSPoint(x: env.midX, y: env.minY + h * 0.42))
    flap.line(to: NSPoint(x: env.maxX - s * 0.02, y: env.maxY - s * 0.02))
    flap.lineWidth = s * 0.035
    flap.lineJoinStyle = .round
    flap.lineCapStyle = .round
    flap.stroke()

    // искра агента
    let c = NSPoint(x: env.maxX - s * 0.02, y: env.maxY + s * 0.04)
    let r = s * 0.11
    let star = NSBezierPath()
    for i in 0..<8 {
        let a = CGFloat(i) * .pi / 4 + .pi / 2
        let rr = i % 2 == 0 ? r : r * 0.32
        let p = NSPoint(x: c.x + cos(a) * rr, y: c.y + sin(a) * rr)
        if i == 0 { star.move(to: p) } else { star.line(to: p) }
    }
    star.close()
    NSColor(red: 0.78, green: 0.62, blue: 1.0, alpha: 1).setFill()
    star.fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! draw(px).write(to: URL(fileURLWithPath: "\(iconset)/icon_\(name).png"))
}
print(iconset)
