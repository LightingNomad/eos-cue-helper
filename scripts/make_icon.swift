// Renders Resources/AppIcon.icns. Run: swift scripts/make_icon.swift
import AppKit

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.09
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = NSBezierPath(roundedRect: rect, xRadius: s * 0.19, yRadius: s * 0.19)
    NSGradient(colors: [NSColor(red: 0.10, green: 0.11, blue: 0.16, alpha: 1),
                        NSColor(red: 0.20, green: 0.16, blue: 0.30, alpha: 1)])!.draw(in: path, angle: -90)
    // Light beam
    let beam = NSBezierPath()
    beam.move(to: NSPoint(x: s * 0.42, y: s * 0.70))
    beam.line(to: NSPoint(x: s * 0.58, y: s * 0.70))
    beam.line(to: NSPoint(x: s * 0.80, y: s * 0.20))
    beam.line(to: NSPoint(x: s * 0.20, y: s * 0.20))
    beam.close()
    NSGradient(colors: [NSColor(red: 1, green: 0.78, blue: 0.35, alpha: 0.85),
                        NSColor(red: 1, green: 0.78, blue: 0.35, alpha: 0.0)])!.draw(in: beam, angle: -90)
    // Fixture
    NSColor(red: 1, green: 0.82, blue: 0.45, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: s * 0.36, y: s * 0.68, width: s * 0.28, height: s * 0.14),
                 xRadius: s * 0.03, yRadius: s * 0.03).fill()
    // "GO" text
    let para = NSMutableParagraphStyle(); para.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: s * 0.17, weight: .heavy),
        .foregroundColor: NSColor.white,
        .paragraphStyle: para,
    ]
    ("CUE" as NSString).draw(in: NSRect(x: 0, y: s * 0.17, width: s, height: s * 0.22), withAttributes: attrs)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let set = URL(fileURLWithPath: "build/AppIcon.iconset")
try? fm.removeItem(at: set)
try! fm.createDirectory(at: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: set.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: set.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", "Resources/AppIcon.icns"]
try! p.run(); p.waitUntilExit()
print("Wrote Resources/AppIcon.icns")
