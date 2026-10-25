#!/usr/bin/swift
import AppKit
import Foundation

// Reproducible geometric marks. No wallpaper fragments or generated textures.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let names = ["minimal-ink", "minimal-frame"]
let manager = FileManager.default
let originals = root.appendingPathComponent("Artwork/AppIcons/Minimal")
try manager.createDirectory(at: originals, withIntermediateDirectories: true)
let temporary = manager.temporaryDirectory.appendingPathComponent("fangcun-minimal-icons-" + UUID().uuidString)
try manager.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? manager.removeItem(at: temporary) }
func raster(size: Int, name: String, menu: Bool = false) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    bitmap.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let scale = CGFloat(size) / 1024
    let transform = AffineTransform(scale: scale); (transform as NSAffineTransform).concat()
    NSColor.clear.setFill(); NSRect(x: 0, y: 0, width: 1024, height: 1024).fill(using: .copy)
    let ink = NSColor(srgbRed: 0.12, green: 0.14, blue: 0.18, alpha: 1)
    let paper = NSColor(srgbRed: 0.96, green: 0.96, blue: 0.95, alpha: 1)
    if !menu {
        (name == "minimal-ink" ? ink : paper).setFill()
        NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 202, yRadius: 202).fill()
    }
    let mark = NSBezierPath(); mark.lineCapStyle = .round; mark.lineJoinStyle = .round
    mark.lineWidth = menu ? 74 : 58
    (menu ? NSColor.black : name == "minimal-ink" ? paper : ink).setStroke()
    if name == "minimal-ink" {
        mark.move(to: NSPoint(x: 360, y: 300)); mark.line(to: NSPoint(x: 360, y: 716)); mark.line(to: NSPoint(x: 690, y: 716))
        mark.move(to: NSPoint(x: 360, y: 516)); mark.line(to: NSPoint(x: 620, y: 516))
    } else {
        for (x, y, dx, dy) in [(322.0,322.0,138.0,138.0),(702,322,-138,138),(322,702,138,-138),(702,702,-138,-138)] {
            mark.move(to: NSPoint(x: x, y: y + dy)); mark.line(to: NSPoint(x: x, y: y)); mark.line(to: NSPoint(x: x + dx, y: y))
        }
    }
    if menu {
        // Enlarge only the monochrome mark to use the menu bar's small canvas.
        let magnify = AffineTransform(translationByX: -210, byY: -210)
        mark.transform(using: magnify)
        mark.transform(using: AffineTransform(scale: 1.7))
    }
    mark.stroke(); NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}
let variants = [(16,"16x16"),(32,"16x16@2x"),(32,"32x32"),(64,"32x32@2x"),(128,"128x128"),(256,"128x128@2x"),(256,"256x256"),(512,"256x256@2x"),(512,"512x512"),(1024,"512x512@2x")]
for name in names {
    try raster(size: 1024, name: name).write(to: originals.appendingPathComponent(name + ".png"))
    let iconset = temporary.appendingPathComponent(name + ".iconset")
    try manager.createDirectory(at: iconset, withIntermediateDirectories: true)
    for (size, suffix) in variants { try raster(size: size, name: name).write(to: iconset.appendingPathComponent("icon_" + suffix + ".png")) }
    let output = root.appendingPathComponent("Resources/AppIcons/" + name + ".icns")
    let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    process.arguments = ["-c", "icns", "-o", output.path, iconset.path]; try process.run(); process.waitUntilExit()
    guard process.terminationStatus == 0 else { fatalError("iconutil failed") }
    try raster(size: 72, name: name, menu: true).write(to: root.appendingPathComponent("Resources/AppIcons/" + name + "-menubar.png"))
    print("Prepared " + name + ": ten icon representations and a monochrome menu-bar mark")
}
try Data(contentsOf: root.appendingPathComponent("Resources/AppIcons/minimal-ink.icns")).write(to: root.appendingPathComponent("Resources/AppIcon.icns"), options: .atomic)
try raster(size: 256, name: "minimal-ink").write(to: root.appendingPathComponent("Resources/PanelLogo.png"), options: .atomic)
