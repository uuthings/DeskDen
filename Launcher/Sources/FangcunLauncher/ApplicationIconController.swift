import AppKit
import Combine
import Foundation

enum ApplicationIconChoice: String, CaseIterable, Identifiable {
    case desk
    var id: String { rawValue }
    var title: String { "桌面" }
    var subtitle: String { "暖米灰 · 工作窗口与桌面" }
    static func restored(_ value: String?) -> Self {
        // Retired landscape, 墨白 and 留白 choices all migrate to the approved identity.
        .desk
    }
}

/// One approved identity with separate artwork for the Dock, small brand marks and menu bar.
/// Applying the running icon never changes the signed bundle.
@MainActor final class ApplicationIconController: ObservableObject {
    static let shared = ApplicationIconController()
    static let changedNotification = Notification.Name("Fangcun.applicationIcon.changed")
    static let preferenceKey = "Fangcun.applicationIcon"
    @Published private(set) var selection: ApplicationIconChoice
    @Published private(set) var error: String?

    private let defaults: UserDefaults
    private let loadImage: @MainActor (ApplicationIconChoice) -> NSImage?
    private let loadSmallImage: @MainActor () -> NSImage?
    private let loadMenuImage: @MainActor () -> NSImage?
    private let applyImage: @MainActor (NSImage) -> Void
    private var images: [ApplicationIconChoice: NSImage] = [:]
    private var smallImage: NSImage?
    private var menuImage: NSImage?

    init(defaults: UserDefaults = .standard,
         loadImage: @escaping @MainActor (ApplicationIconChoice) -> NSImage? = ApplicationIconController.bundleImage,
         loadSmallImage: @escaping @MainActor () -> NSImage? = { ApplicationIconController.bundleSmallImage() },
         loadMenuImage: @escaping @MainActor () -> NSImage? = { ApplicationIconController.bundleMenuBarImage() },
         applyImage: @escaping @MainActor (NSImage) -> Void = { NSApplication.shared.applicationIconImage = $0 }) {
        self.defaults = defaults
        self.loadImage = loadImage
        self.loadSmallImage = loadSmallImage
        self.loadMenuImage = loadMenuImage
        self.applyImage = applyImage
        selection = ApplicationIconChoice.restored(defaults.string(forKey: Self.preferenceKey))
    }

    func image(for choice: ApplicationIconChoice) -> NSImage? {
        if let image = images[choice] { return image }
        guard let image = loadImage(choice), image.isValid else { return nil }
        images[choice] = image
        return image
    }

    func brandImage(pointSize: CGFloat) -> NSImage? {
        if pointSize <= 32 {
            if let smallImage { return smallImage }
            if let image = loadSmallImage(), image.isValid {
                smallImage = image
                return image
            }
        }
        return image(for: selection)
    }

    func menuBarImage() -> NSImage? {
        if let menuImage { return menuImage }
        guard let image = loadMenuImage(), image.isValid else { return nil }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        menuImage = image
        return image
    }

    /// Called after normal application launch; test commands do not apply an icon.
    @discardableResult func applyCurrentIcon() -> Bool {
        guard let image = image(for: selection) else {
            error = "暂时无法读取应用图标。"
            return false
        }
        applyImage(image)
        defaults.set(selection.rawValue, forKey: Self.preferenceKey)
        NotificationCenter.default.post(name: Self.changedNotification, object: self)
        error = nil
        return true
    }

    static func bundleSmallImage(resourceDirectory: URL? = Bundle.main.resourceURL) -> NSImage? {
        bitmapImage(named: "desk-small", pointSize: 32, template: false, resourceDirectory: resourceDirectory)
    }

    static func bundleMenuBarImage(resourceDirectory: URL? = Bundle.main.resourceURL) -> NSImage? {
        bitmapImage(named: "desk-menubar", pointSize: 18, template: true, resourceDirectory: resourceDirectory)
    }

    private static func bitmapImage(named name: String, pointSize: Int, template: Bool, resourceDirectory: URL?) -> NSImage? {
        guard let directory = resourceDirectory?.appendingPathComponent("AppIcons", isDirectory: true) else { return nil }
        let size = NSSize(width: pointSize, height: pointSize)
        let image = NSImage(size: size)
        for (suffix, scale) in [("-1x", 1), ("", 2)] {
            let url = directory.appendingPathComponent(name + suffix + ".png")
            guard let data = try? Data(contentsOf: url), let representation = NSBitmapImageRep(data: data),
                  representation.pixelsWide == pointSize * scale,
                  representation.pixelsHigh == pointSize * scale else { continue }
            // Both densities share a point size; their pixel dimensions remain distinct.
            representation.size = size
            image.addRepresentation(representation)
        }
        guard !image.representations.isEmpty else { return nil }
        image.isTemplate = template
        return image
    }
    static func bundleImage(_ choice: ApplicationIconChoice) -> NSImage? {
        guard let resource = Bundle.main.resourceURL?.appendingPathComponent("AppIcons", isDirectory: true)
            .appendingPathComponent(choice.rawValue + ".icns") else { return nil }
        return NSImage(contentsOf: resource)
    }
}
