#!/usr/bin/swift
import AppKit
import CryptoKit
import Foundation

// Package the approved pixels without redrawing or resampling the artwork.
// Editable SVG masters and optical-size raster sources are kept together.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let manager = FileManager.default
let artwork = root.appendingPathComponent("Artwork/AppIcons")
let sources = artwork.appendingPathComponent("Desk")
let resources = root.appendingPathComponent("Resources")
let iconDirectory = resources.appendingPathComponent("AppIcons")
try manager.createDirectory(at: iconDirectory, withIntermediateDirectories: true)

let slots: [(String, Int)] = [
    ("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64),
    ("128x128", 128), ("128x128@2x", 256), ("256x256", 256),
    ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)
]
let copies: [(String, String, Int)] = [
    ("desk-panel.png", "Resources/PanelLogo.png", 256),
    ("desk-small.png", "Resources/AppIcons/desk-small.png", 64),
    ("desk-small-1x.png", "Resources/AppIcons/desk-small-1x.png", 32),
    ("desk-menubar.png", "Resources/AppIcons/desk-menubar.png", 36),
    ("desk-menubar-1x.png", "Resources/AppIcons/desk-menubar-1x.png", 18)
]

func data(at url: URL) throws -> Data {
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard values.isRegularFile == true, values.isSymbolicLink != true else {
        throw NSError(domain: "DeskIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected a regular artwork file: " + url.lastPathComponent])
    }
    return try Data(contentsOf: url)
}
func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
func validatePNG(_ url: URL, pixels: Int) throws -> Data {
    let bytes = try data(at: url)
    guard let bitmap = NSBitmapImageRep(data: bytes), bitmap.pixelsWide == pixels,
          bitmap.pixelsHigh == pixels, bitmap.hasAlpha else {
        throw NSError(domain: "DeskIcon", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid approved representation: " + url.lastPathComponent])
    }
    return bytes
}

var sourceRecords: [[String: Any]] = []
for name in ["app-master.svg", "app-small.svg", "menu-template-16.svg", "menu-template-18.svg", "menu-template-20.svg"] {
    let bytes = try data(at: sources.appendingPathComponent(name))
    sourceRecords.append(["path": "Desk/" + name, "sha256": hash(bytes)])
}
for (suffix, pixels) in slots {
    let name = "desk.iconset/icon_" + suffix + ".png"
    let bytes = try validatePNG(sources.appendingPathComponent(name), pixels: pixels)
    sourceRecords.append(["path": "Desk/" + name, "sha256": hash(bytes), "pixels": pixels])
}
var productionRecords: [[String: Any]] = []
for (source, destination, pixels) in copies {
    let bytes = try validatePNG(sources.appendingPathComponent(source), pixels: pixels)
    try bytes.write(to: root.appendingPathComponent(destination), options: .atomic)
    sourceRecords.append(["path": "Desk/" + source, "sha256": hash(bytes), "pixels": pixels])
    productionRecords.append(["path": destination, "source": "Desk/" + source, "sha256": hash(bytes), "pixels": pixels])
}

let output = iconDirectory.appendingPathComponent("desk.icns")
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", "-o", output.path, sources.appendingPathComponent("desk.iconset").path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { fatalError("iconutil failed") }
let icon = try data(at: output)
try icon.write(to: resources.appendingPathComponent("AppIcon.icns"), options: .atomic)
for destination in ["Resources/AppIcons/desk.icns", "Resources/AppIcon.icns"] {
    productionRecords.append(["path": destination, "source": "Desk/desk.iconset", "sha256": hash(icon)])
}
let provenance: [String: Any] = [
    "schema": 1, "id": "desk",
    "method": "Approved desktop outline SVG masters with separately rasterized optical-size representations. Packaging copies approved pixels directly; iconutil combines the ten standard representations without resampling.",
    "sources": sourceRecords, "production": productionRecords
]
try JSONSerialization.data(withJSONObject: provenance, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    .write(to: artwork.appendingPathComponent("provenance-desk.json"), options: .atomic)
print("Prepared desk: default bundle icon, ten ICNS representations, panel branding, and 1x/2x in-app and menu-bar artwork.")
