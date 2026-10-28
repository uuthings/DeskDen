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
        let suite = "deskden.application-icon-checks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var images: [ApplicationIconChoice: NSImage] = [:]
        for choice in ApplicationIconChoice.allCases {
            let url = root.appendingPathComponent("Resources/AppIcons/" + choice.rawValue + ".icns")
            let source = root.appendingPathComponent("Artwork/AppIcons/Desk/desk.iconset/icon_512x512@2x.png")
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
        let firstData = try? Data(contentsOf: root.appendingPathComponent("Resources/AppIcons/desk.icns"))
        check(defaultData != nil && defaultData == firstData, "Finder and running app use the same approved desk ICNS")
        check(ApplicationIconChoice.allCases == [.desk], "only the approved desk identity is available")
        let resources = root.appendingPathComponent("Resources")
        let small = ApplicationIconController.bundleSmallImage(resourceDirectory: resources)
        let menu = ApplicationIconController.bundleMenuBarImage(resourceDirectory: resources)
        check(validRepresentations(small, pointSize: 32, pixels: [32, 64], template: false),
              "small brand image retains separate 1x and 2x representations at 32 points")
        check(validRepresentations(menu, pointSize: 18, pixels: [18, 36], template: true),
              "menu-bar template retains separate 1x and 2x representations at 18 points")
        for (name, dimension) in [("desk-menubar-1x", 18), ("desk-menubar", 36)] {
            let menuBitmap = bitmap(at: resources.appendingPathComponent("AppIcons/" + name + ".png"))
            check(menuBitmap.map { $0.pixelsWide == dimension && $0.pixelsHigh == dimension && isTransparentBlackMark($0) } == true,
                  name + " is an independent black alpha template without a filled app tile")
        }
        var applied: [NSImage] = []
        var smallLoads = 0, menuLoads = 0
        let controller = ApplicationIconController(defaults: defaults, loadImage: { images[$0] },
            loadSmallImage: { smallLoads += 1; return small }, loadMenuImage: { menuLoads += 1; return menu },
            applyImage: { applied.append($0) })
        check(controller.selection == .desk && applied.isEmpty && defaults.string(forKey: ApplicationIconController.preferenceKey) == nil,
              "clean initialization neither applies an app icon nor writes a preference")
        check(controller.applyCurrentIcon() && applied.last === images[.desk] && defaults.string(forKey: ApplicationIconController.preferenceKey) == "desk",
              "successful startup applies and persists the approved desk identity")
        check(controller.brandImage(pointSize: 25) === small && controller.brandImage(pointSize: 27) === small && controller.brandImage(pointSize: 32) === small && smallLoads == 1,
              "header, launcher and Mini share one cached optical small image")
        check(controller.brandImage(pointSize: 36) === images[.desk] && controller.brandImage(pointSize: 64) === images[.desk],
              "welcome and settings use the full-resolution approved artwork")
        check(controller.menuBarImage() === menu && controller.menuBarImage() === menu && menuLoads == 1,
              "menu-bar access reuses one independent template instead of the app tile")
        for old in ["minimal-ink", "minimal-frame", "qingbi-chenwu", "yuebai-yunhai", "nuanxia-xuanshan", "removed-legacy-icon"] {
            defaults.set(old, forKey: ApplicationIconController.preferenceKey)
            defaults.set("preserved", forKey: "unrelated.preference")
            let migrated = ApplicationIconController(defaults: defaults, loadImage: { images[$0] }, applyImage: { applied.append($0) })
            check(migrated.selection == .desk && defaults.string(forKey: ApplicationIconController.preferenceKey) == old,
                  old + " resolves to desk without changing preferences during initialization")
            check(migrated.applyCurrentIcon() && defaults.string(forKey: ApplicationIconController.preferenceKey) == "desk" && defaults.string(forKey: "unrelated.preference") == "preserved",
                  old + " migrates after a valid image is applied and preserves unrelated settings")
        }
        let restored = ApplicationIconController(defaults: defaults, loadImage: { images[$0] }, applyImage: { applied.append($0) })
        check(restored.selection == .desk && restored.applyCurrentIcon() && applied.last === images[.desk],
              "the migrated identity survives controller recreation")
        defaults.set("minimal-frame", forKey: ApplicationIconController.preferenceKey)
        let before = defaults.string(forKey: ApplicationIconController.preferenceKey)
        let missing = ApplicationIconController(defaults: defaults, loadImage: { _ in nil }, applyImage: { _ in failures += 1 })
        check(!missing.applyCurrentIcon() && missing.error != nil && defaults.string(forKey: ApplicationIconController.preferenceKey) == before,
              "missing artwork preserves the old stored preference and never applies an invalid image")
        let fallback = ApplicationIconController(defaults: defaults, loadImage: { images[$0] }, loadSmallImage: { nil }, loadMenuImage: { nil }, applyImage: { _ in })
        check(fallback.brandImage(pointSize: 25) === images[.desk] && fallback.menuBarImage() == nil,
              "missing small artwork falls back only to the approved icon; missing menu artwork never displays a tile")
        print("Application icon checks: \(count) checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
    private static func bitmap(at url: URL) -> NSBitmapImageRep? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return NSBitmapImageRep(data: data)
    }
    private static func validRepresentations(_ image: NSImage?, pointSize: Int, pixels: Set<Int>, template: Bool) -> Bool {
        guard let image, image.isValid, image.isTemplate == template else { return false }
        let size = NSSize(width: pointSize, height: pointSize)
        let representations = image.representations.compactMap { $0 as? NSBitmapImageRep }
        return image.size == size && representations.count == pixels.count && Set(representations.map(\.pixelsWide)) == pixels && representations.allSatisfy {
            $0.pixelsWide == $0.pixelsHigh && $0.hasAlpha && $0.size == size && ($0.colorAt(x: 0, y: 0)?.alphaComponent ?? 1) == 0
        }
    }
    private static func isTransparentBlackMark(_ bitmap: NSBitmapImageRep) -> Bool {
        guard bitmap.hasAlpha else { return false }
        var opaquePixels = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
                if x == 0 || y == 0 || x == bitmap.pixelsWide - 1 || y == bitmap.pixelsHigh - 1 {
                    guard color.alphaComponent == 0 else { return false }
                }
                if color.alphaComponent > 0.05 {
                    guard max(color.redComponent, color.greenComponent, color.blueComponent) < 0.02 else { return false }
                    opaquePixels += 1
                }
            }
        }
        return opaquePixels > 0 && opaquePixels < bitmap.pixelsWide * bitmap.pixelsHigh / 2
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
