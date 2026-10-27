#!/usr/bin/swift
import AppKit
import CryptoKit
import Foundation

// Reuse the Desk optical-size vector geometry with a larger mark for Chrome's
// fixed 16-DIP action slot. This does not modify the application icon suite.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let source = root.appendingPathComponent("Artwork/AppIcons/Desk/app-small.svg")
let destination = root.appendingPathComponent("BrowserConnectors/IPRoyal", isDirectory: true)
let sourceValues = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
guard sourceValues.isRegularFile == true, sourceValues.isSymbolicLink != true else {
    fatalError("Expected the regular Desk small-size SVG source")
}
let sourceHash = SHA256.hash(data: try Data(contentsOf: source)).map { String(format: "%02x", $0) }.joined()
guard sourceHash == "31bdfdc450d06e732566600d59318eaad07dc4392d959ca3c6d758d3f353f6c7" else {
    fatalError("Desk SVG changed; review its geometry before rebuilding connector icons")
}

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> CGColor {
    CGColor(colorSpace: colorSpace, components: [red / 255, green / 255, blue / 255, 1])!
}
let surface = CGGradient(colorsSpace: colorSpace,
    colors: [color(247, 243, 236), color(238, 232, 222)] as CFArray,
    locations: [0, 1])!
let stroke = color(73, 69, 63)

for pixels in [16, 32, 64, 128] {
    guard let context = CGContext(data: nil, width: pixels, height: pixels,
        bitsPerComponent: 8, bytesPerRow: pixels * 4, space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("Could not create the icon drawing surface")
    }
    context.setShouldAntialias(true)
    context.translateBy(x: 0, y: CGFloat(pixels))
    context.scaleBy(x: CGFloat(pixels) / 1024, y: -CGFloat(pixels) / 1024)

    // Use the entire square canvas for the warm tile; retain rounded corners.
    context.saveGState()
    context.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: 1024, height: 1024),
                           cornerWidth: 192, cornerHeight: 192, transform: nil))
    context.clip()
    context.drawLinearGradient(surface, start: CGPoint(x: 512, y: 0),
                               end: CGPoint(x: 512, y: 1024), options: [])
    context.restoreGState()

    // The source uses 1.06. This yields a 30.0 x 24.5px mark on a 32px canvas,
    // retaining one pixel of horizontal clearance without stretching the mark.
    context.translateBy(x: 512, y: 505)
    context.scaleBy(x: 1.95, y: 1.95)
    context.translateBy(x: -512, y: -505)
    context.setStrokeColor(stroke)
    context.setLineWidth(32)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.addPath(CGPath(roundedRect: CGRect(x: 324, y: 320, width: 376, height: 216),
                           cornerWidth: 42, cornerHeight: 42, transform: nil))
    context.strokePath()
    context.move(to: CGPoint(x: 282, y: 606))
    context.addLine(to: CGPoint(x: 742, y: 606))
    context.move(to: CGPoint(x: 330, y: 606))
    context.addLine(to: CGPoint(x: 330, y: 690))
    context.move(to: CGPoint(x: 694, y: 606))
    context.addLine(to: CGPoint(x: 694, y: 690))
    context.strokePath()

    guard let image = context.makeImage(),
          let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        fatalError("Could not encode the connector icon")
    }
    try data.write(to: destination.appendingPathComponent("icon-\(pixels).png"), options: .atomic)
}
print("Prepared four larger Desk connector icons; application artwork is unchanged.")
