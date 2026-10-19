// Draws Clementine's app icon (a whole clementine with a leaf on a cream squircle)
// and writes Resources/AppIcon.icns.   swift Scripts/make-icon.swift
import AppKit

func icon(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let cg = NSGraphicsContext.current!.cgContext
    func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a).cgColor }

    // macOS icon grid: 824/1024 squircle, centred, with a soft shadow.
    let tile = CGRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8)
    let squircle = CGPath(roundedRect: tile, cornerWidth: s * 0.18, cornerHeight: s * 0.18, transform: nil)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.03, color: rgb(0, 0, 0, 0.3))
    cg.addPath(squircle); cg.setFillColor(rgb(255, 248, 238)); cg.fillPath()
    cg.restoreGState()
    cg.saveGState()
    cg.addPath(squircle); cg.clip()
    cg.drawLinearGradient(CGGradient(colorsSpace: nil, colors: [rgb(255, 252, 246), rgb(250, 236, 220)] as CFArray, locations: [0, 1])!,
                          start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])
    cg.restoreGState()

    // The fruit: a slightly squat orange ball, radial gradient, specular highlight.
    let c = CGPoint(x: s * 0.5, y: s * 0.46), rx = s * 0.27, ry = s * 0.25
    let fruit = CGPath(ellipseIn: CGRect(x: c.x - rx, y: c.y - ry, width: 2 * rx, height: 2 * ry), transform: nil)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -s * 0.015), blur: s * 0.035, color: rgb(170, 70, 0, 0.35))
    cg.addPath(fruit); cg.setFillColor(rgb(245, 120, 20)); cg.fillPath()
    cg.restoreGState()
    cg.saveGState()
    cg.addPath(fruit); cg.clip()
    cg.drawRadialGradient(CGGradient(colorsSpace: nil, colors: [rgb(255, 178, 60), rgb(250, 128, 18), rgb(222, 88, 10)] as CFArray, locations: [0, 0.55, 1])!,
                          startCenter: CGPoint(x: c.x - rx * 0.35, y: c.y + ry * 0.4), startRadius: 0,
                          endCenter: c, endRadius: rx * 1.05, options: [.drawsAfterEndLocation])
    cg.setFillColor(rgb(255, 255, 255, 0.35))
    cg.fillEllipse(in: CGRect(x: c.x - rx * 0.62, y: c.y + ry * 0.28, width: rx * 0.5, height: ry * 0.32))
    cg.restoreGState()

    // Stem dimple and leaf.
    let top = CGPoint(x: c.x + s * 0.01, y: c.y + ry - s * 0.012)
    cg.setFillColor(rgb(120, 80, 20)); cg.fillEllipse(in: CGRect(x: top.x - s * 0.018, y: top.y - s * 0.01, width: s * 0.036, height: s * 0.022))
    let leaf = CGMutablePath()
    leaf.move(to: top)
    leaf.addCurve(to: CGPoint(x: top.x + s * 0.2, y: top.y + s * 0.12), control1: CGPoint(x: top.x + s * 0.03, y: top.y + s * 0.13), control2: CGPoint(x: top.x + s * 0.13, y: top.y + s * 0.16))
    leaf.addCurve(to: top, control1: CGPoint(x: top.x + s * 0.17, y: top.y + s * 0.03), control2: CGPoint(x: top.x + s * 0.07, y: top.y - s * 0.01))
    cg.saveGState()
    cg.addPath(leaf); cg.clip()
    cg.drawLinearGradient(CGGradient(colorsSpace: nil, colors: [rgb(120, 200, 80), rgb(40, 140, 60)] as CFArray, locations: [0, 1])!,
                          start: CGPoint(x: top.x, y: top.y + s * 0.15), end: top, options: [])
    cg.restoreGState()
    cg.setStrokeColor(rgb(30, 110, 50, 0.6)); cg.setLineWidth(s * 0.006); cg.setLineCap(.round)
    cg.move(to: CGPoint(x: top.x + s * 0.02, y: top.y + s * 0.02)); cg.addLine(to: CGPoint(x: top.x + s * 0.16, y: top.y + s * 0.11)); cg.strokePath()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let set = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for pt in [16, 32, 128, 256, 512] {
    try! icon(pt).write(to: set.appendingPathComponent("icon_\(pt)x\(pt).png"))
    try! icon(pt * 2).write(to: set.appendingPathComponent("icon_\(pt)x\(pt)@2x.png"))
}
let out = root.appendingPathComponent("Resources/AppIcon.icns")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", out.path]
try! p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "wrote \(out.path)" : "iconutil failed")
exit(p.terminationStatus)
