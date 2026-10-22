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
        let defaultData = try? Data(contentsOf: root.appendingPathComponent("Resources/AppIcon.icns"))
        let firstData = try? Data(contentsOf: root.appendingPathComponent("Resources/AppIcons/qingbi-chenwu.icns"))
        check(defaultData != nil && defaultData == firstData, "bundle icon is exactly the approved default 青碧晨雾")
        var applied: [NSImage] = []
        let controller = ApplicationIconController(defaults: defaults, loadImage: { images[$0] }, applyImage: { applied.append($0) })
        check(controller.selection == .qingbiChenwu && applied.isEmpty, "clean install chooses 青碧晨雾 without affecting an app during initialization")
        check(controller.applyCurrentIcon() && applied.last === images[.qingbiChenwu], "normal startup applies the selected real icon to the injected app hook")
        for choice in ApplicationIconChoice.allCases {
            check(controller.select(choice) && controller.selection == choice && applied.last === images[choice], choice.title + " selection updates the running icon")
            let restored = ApplicationIconController(defaults: defaults, loadImage: { images[$0] }, applyImage: { applied.append($0) })
            check(restored.selection == choice && restored.applyCurrentIcon() && applied.last === images[choice], choice.title + " survives controller recreation and reapplies at startup")
        }
        let before = defaults.string(forKey: ApplicationIconController.preferenceKey)
        let missing = ApplicationIconController(defaults: defaults, loadImage: { _ in nil }, applyImage: { _ in failures += 1 })
        check(!missing.select(.qingbiChenwu) && missing.selection == .nuanxiaXuanshan && missing.error != nil && defaults.string(forKey: ApplicationIconController.preferenceKey) == before,
              "missing artwork keeps the previous persisted selection and shows an error without applying an invalid icon")
        defaults.set("removed-legacy-icon", forKey: ApplicationIconController.preferenceKey)
        let fallback = ApplicationIconController(defaults: defaults, loadImage: { images[$0] }, applyImage: { _ in })
        check(fallback.selection == .qingbiChenwu, "unsupported stored icon value safely falls back to the default")
        print("Application icon checks: \(count) checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
