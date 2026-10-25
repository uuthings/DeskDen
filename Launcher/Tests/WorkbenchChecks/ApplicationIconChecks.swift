import AppKit
import Foundation

@main @MainActor enum ApplicationIconChecks {
    static func main() {
        var count = 0, failures = 0
        func check(_ condition: Bool, _ message: String) {
            count += 1
            if !condition { failures += 1 }
            print("\(condition ? "PASS" : "FAIL") \(message)")
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let suite = "fangcun.application-icon-checks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var images: [ApplicationIconChoice: NSImage] = [:]
        for choice in ApplicationIconChoice.allCases {
            let url = root.appendingPathComponent("Resources/AppIcons/" + choice.rawValue + ".icns")
            let source = root.appendingPathComponent("Artwork/AppIcons/Minimal/" + choice.rawValue + ".png")
            let sourceBitmap = bitmap(at: source)
            let validSource = sourceBitmap.map { bitmap in
                let sizeMatches = bitmap.pixelsWide == 1024 && bitmap.pixelsHigh == 1024
                let clearExterior = bitmap.colorAt(x: 0, y: 0)?.alphaComponent == 0
                let visibleInterior = (bitmap.colorAt(x: 512, y: 512)?.alphaComponent ?? 0) > 0.1
                return sizeMatches && bitmap.hasAlpha && clearExterior && visibleInterior
            } ?? false
            check(validSource,
                  choice.title + " has a reproducible 1024-square geometric PNG with transparent exterior")
            let representationTypes = iconRepresentationTypes(at: url)
            check(representationTypes == Set(["ic04", "ic05", "ic07", "ic08", "ic09", "ic10", "ic11", "ic12", "ic13", "ic14"]),
                  choice.title + " ICNS contains exactly the ten standard image representations")
            guard let image = NSImage(contentsOf: url), image.isValid else {
                check(false, "approved icon resource decodes: " + choice.rawValue)
                continue
            }
            images[choice] = image
            let bitmaps = image.representations.compactMap { $0 as? NSBitmapImageRep }
            let widths = Set(bitmaps.map(\.pixelsWide))
            check(Set([16, 32, 64, 128, 256, 512, 1024]).isSubset(of: widths) && bitmaps.allSatisfy { $0.pixelsWide == $0.pixelsHigh && $0.hasAlpha },
                  choice.title + " contains square 16–1024 pixel representations with alpha")
            let transparentEdges = bitmaps.allSatisfy { bitmap in
                [(0, 0), (bitmap.pixelsWide - 1, 0), (0, bitmap.pixelsHigh - 1), (bitmap.pixelsWide - 1, bitmap.pixelsHigh - 1)]
                    .allSatisfy { bitmap.colorAt(x: $0.0, y: $0.1)?.alphaComponent == 0 }
            }
            check(transparentEdges, choice.title + " preserves transparent exterior corners at every size")
        }
        for name in ["ar-world", "thunder-cabin", "qingbi-chenwu", "yuebai-yunhai", "nuanxia-xuanshan"] {
            let background = bitmap(at: root.appendingPathComponent("Resources/Workbench/" + name + ".jpg"))
            check(background.map { $0.pixelsWide >= 1000 && $0.pixelsHigh >= 500 && !$0.hasAlpha } == true,
                  "production theme background decodes as an opaque landscape: " + name)
        }
        for name in ["qingbi-chenwu", "yuebai-yunhai", "nuanxia-xuanshan"] {
            let source = bitmap(at: root.appendingPathComponent("Artwork/Workbench/" + name + ".png"))
            let production = bitmap(at: root.appendingPathComponent("Resources/Workbench/" + name + ".jpg"))
            let validSource = source.map { $0.pixelsWide == 1672 && $0.pixelsHigh == 941 && !$0.hasAlpha } ?? false
            let validProduction = production.map { $0.pixelsWide == 1672 && $0.pixelsHigh == 941 } ?? false
            check(validSource && validProduction,
                  name + " wallpaper preserves its actual 1672 by 941 source dimensions without enlargement or cropping")
        }
        let defaultData = try? Data(contentsOf: root.appendingPathComponent("Resources/AppIcon.icns"))
        let firstData = try? Data(contentsOf: root.appendingPathComponent("Resources/AppIcons/minimal-ink.icns"))
        check(defaultData != nil && defaultData == firstData, "bundle icon is exactly the approved default 墨白")
        var applied: [NSImage] = []
        let controller = ApplicationIconController(defaults: defaults, loadImage: { images[$0] }, applyImage: { applied.append($0) })
        check(controller.selection == .ink && applied.isEmpty, "clean install chooses 墨白 without affecting an app during initialization")
        check(controller.applyCurrentIcon() && applied.last === images[.ink], "normal startup applies the selected real icon to the injected app hook")
        for choice in ApplicationIconChoice.allCases {
            check(controller.select(choice) && controller.selection == choice && applied.last === images[choice], choice.title + " selection updates the running icon")
            let restored = ApplicationIconController(defaults: defaults, loadImage: { images[$0] }, applyImage: { applied.append($0) })
            check(restored.selection == choice && restored.applyCurrentIcon() && applied.last === images[choice], choice.title + " survives controller recreation and reapplies at startup")
        }
        check(ApplicationIconChoice.allCases.count == 2, "exactly two minimal application icons are offered")
        for old in ["qingbi-chenwu", "yuebai-yunhai", "nuanxia-xuanshan"] {
            check(ApplicationIconChoice.allCases.contains(ApplicationIconChoice.restored(old)), "historical icon choice maps to an available minimal mark")
        }
        for choice in ApplicationIconChoice.allCases {
            let menu = bitmap(at: root.appendingPathComponent("Resources/AppIcons/" + choice.rawValue + "-menubar.png"))
            check(menu.map { $0.pixelsWide == 72 && $0.pixelsHigh == 72 && $0.hasAlpha && ($0.colorAt(x: 0, y: 0)?.alphaComponent ?? 1) == 0 } == true,
                  "monochrome menu-bar mark has a transparent 72-square production resource")
        }
        let before = defaults.string(forKey: ApplicationIconController.preferenceKey)
        let missing = ApplicationIconController(defaults: defaults, loadImage: { _ in nil }, applyImage: { _ in failures += 1 })
        check(!missing.select(.ink) && missing.selection == .frame && missing.error != nil && defaults.string(forKey: ApplicationIconController.preferenceKey) == before,
              "missing artwork keeps the previous persisted selection and shows an error without applying an invalid icon")
        defaults.set("removed-legacy-icon", forKey: ApplicationIconController.preferenceKey)
        let fallback = ApplicationIconController(defaults: defaults, loadImage: { images[$0] }, applyImage: { _ in })
        check(fallback.selection == .ink, "unsupported stored icon value safely falls back to the default")
        print("Application icon checks: \(count) checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
    private static func bitmap(at url: URL) -> NSBitmapImageRep? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return NSBitmapImageRep(data: data)
    }
    private static func iconRepresentationTypes(at url: URL) -> Set<String>? {
        guard let data = try? Data(contentsOf: url), data.count >= 8, String(data: data.prefix(4), encoding: .ascii) == "icns" else { return nil }
        func integer(_ offset: Int) -> Int { data[offset..<(offset + 4)].reduce(0) { $0 * 256 + Int($1) } }
        guard integer(4) == data.count else { return nil }
        var offset = 8, imageTypes: [String] = []
        while offset < data.count {
            guard offset + 8 <= data.count, let type = String(data: data[offset..<(offset + 4)], encoding: .ascii) else { return nil }
            let length = integer(offset + 4)
            guard length >= 8, offset + length <= data.count else { return nil }
            if type != "info" && type != "TOC " { imageTypes.append(type) }
            offset += length
        }
        guard imageTypes.count == 10, Set(imageTypes).count == 10 else { return nil }
        return Set(imageTypes)
    }
}
