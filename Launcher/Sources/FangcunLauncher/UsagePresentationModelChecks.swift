import AppKit
import ImageIO
import LauncherCore
import UniformTypeIdentifiers

/// Disposable image fixtures; no picker, network, account or Keychain access.
@MainActor enum UsagePresentationModelChecks {
    static func run() -> (count: Int, failures: Int) {
        var count = 0, failures = 0
        func check(_ value: Bool, _ label: String) {
            count += 1; if !value { failures += 1 }
            print("\(value ? "PASS" : "FAIL") \(label)")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fangcun-usage-icons-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let modelDirectory = directory.appendingPathComponent("Display")
            let model = UsagePresentationModel(dataDirectory: modelDirectory)
            let key = UsagePresentationSourceID.ai(.codex)
            check(!model.isCollapsed(.ai) && model.appearance(for: key).visible, "new presentation preserves visible AI cards and expanded groups")
            let source = directory.appendingPathComponent("fixture.png")
            guard let context = CGContext(data: nil, width: 1024, height: 512, bitsPerComponent: 8, bytesPerRow: 4096,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let image = context.makeImage() else { throw UsagePresentationError.image }
            let png = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil) else { throw UsagePresentationError.image }
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFArtist: "fixture artist"]] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw UsagePresentationError.image }
            try (png as Data).write(to: source)
            let icon = try model.importImage(from: source)
            let normalized = model.image(for: icon)
            check(normalized?.size.width == 256 && normalized?.size.height == 128, "custom icon is copied and downsampled while preserving its aspect ratio")
            check(model.saveAppearance(.init(displayName: "  Research  ", icon: icon, visible: false), for: key)
                  && model.setCollapsed(true, group: .service), "display edits save independently from source collection")
            try FileManager.default.removeItem(at: source)
            let restored = UsagePresentationModel(dataDirectory: modelDirectory)
            check(restored.appearance(for: key).displayName == "Research" && !restored.appearance(for: key).visible
                  && restored.isCollapsed(.service) && restored.image(for: icon) != nil, "restart restores appearance and managed icon after original image is removed")
            if case .image(let name) = icon {
                let saved = modelDirectory.appendingPathComponent("Icons").appendingPathComponent(name)
                let data = try Data(contentsOf: saved)
                let decoded = CGImageSourceCreateWithData(data as CFData, nil)!
                let properties = CGImageSourceCopyPropertiesAtIndex(decoded, 0, nil) as? [CFString: Any]
                let metadata = properties?[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
                check(metadata?[kCGImagePropertyTIFFArtist] == nil && data.count <= UsagePresentationModel.maximumStoredImageBytes, "normalized icon does not retain original image metadata")
            }
            let oversized = directory.appendingPathComponent("oversized.png")
            try Data(count: UsagePresentationModel.maximumImportBytes + 1).write(to: oversized)
            check((try? model.importImage(from: oversized)) == nil, "oversized input is rejected before image decoding")
            let malformed = directory.appendingPathComponent("malformed.png")
            try Data("not an image".utf8).write(to: malformed)
            let symlink = directory.appendingPathComponent("linked.png")
            try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: malformed)
            check((try? model.importImage(from: malformed)) == nil && (try? model.importImage(from: symlink)) == nil, "malformed and linked inputs cannot become managed images")
            let configuration = modelDirectory.appendingPathComponent("display-preferences.json")
            let damaged = Data("{invalid".utf8); try damaged.write(to: configuration)
            let protected = UsagePresentationModel(dataDirectory: modelDirectory)
            let rejected = !protected.setCollapsed(true, group: .ai)
            let after = try Data(contentsOf: configuration)
            check(protected.storageError != nil && rejected && after == damaged, "damaged presentation original blocks writes and stays intact")
        } catch { check(false, "presentation fixture failed: \(error.localizedDescription)") }
        print("Usage presentation checks: \(count) checks, \(failures) failures")
        return (count, failures)
    }
}
