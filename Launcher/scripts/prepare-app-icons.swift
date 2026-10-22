#!/usr/bin/swift
import AppKit
import Foundation

// Resample the approved, unmodified artwork with aspect-fit onto transparent
// square canvases. Rounded water-mirror sources keep their clear alpha edges.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let names = ["qingbi-chenwu", "yuebai-yunhai", "nuanxia-xuanshan"]
let variants = [(16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"),
                (128, "128x128"), (256, "128x128@2x"), (256, "256x256"),
                (512, "256x256@2x"), (512, "512x512"), (1024, "512x512@2x")]
let manager = FileManager.default
let temporary = manager.temporaryDirectory.appendingPathComponent("fangcun-app-icons-" + UUID().uuidString)
try manager.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? manager.removeItem(at: temporary) }
for name in names {
    let source = root.appendingPathComponent("Artwork/AppIcons/" + name + ".png")
    guard let image = NSImage(contentsOf: source), image.size.width > 0, image.size.height > 0 else {
        fatalError("Cannot read approved icon source: " + source.path)
    }
    let iconset = temporary.appendingPathComponent(name + ".iconset")
    try manager.createDirectory(at: iconset, withIntermediateDirectories: true)
    for (size, suffix) in variants {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                           isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("Cannot allocate icon canvas") }
        bitmap.size = NSSize(width: size, height: size)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill(using: .copy)
        context.imageInterpolation = .high
        let scale = min(CGFloat(size) / image.size.width, CGFloat(size) / image.size.height)
        let width = image.size.width * scale, height = image.size.height * scale
        image.draw(in: NSRect(x: (CGFloat(size) - width) / 2, y: (CGFloat(size) - height) / 2,
                             width: width, height: height), from: .zero, operation: .copy, fraction: 1,
                   respectFlipped: false, hints: [.interpolation: NSImageInterpolation.high])
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Cannot encode icon") }
        try png.write(to: iconset.appendingPathComponent("icon_" + suffix + ".png"))
    }
    let output = root.appendingPathComponent("Resources/AppIcons/" + name + ".icns")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    process.arguments = ["-c", "icns", "-o", output.path, iconset.path]
    try process.run(); process.waitUntilExit()
    guard process.terminationStatus == 0 else { fatalError("iconutil failed for " + name) }
    print("Prepared " + name + ": ten representations, 16–1024 pixels")
}
let defaultIcon = root.appendingPathComponent("Resources/AppIcon.icns")
try Data(contentsOf: root.appendingPathComponent("Resources/AppIcons/qingbi-chenwu.icns")).write(to: defaultIcon, options: .atomic)
print("Default bundle icon: 青碧晨雾")
