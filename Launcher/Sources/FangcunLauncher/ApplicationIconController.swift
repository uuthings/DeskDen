import AppKit
import Combine
import Foundation

enum ApplicationIconChoice: String, CaseIterable, Identifiable {
    case ink = "minimal-ink"
    case frame = "minimal-frame"
    var id: String { rawValue }
    var title: String { self == .ink ? "墨白" : "留白" }
    var subtitle: String { self == .ink ? "字母 F · 深墨底" : "方寸折角 · 浅瓷底" }
    static func restored(_ value: String?) -> Self {
        if let value, let choice = Self(rawValue: value) { return choice }
        return value == "yuebai-yunhai" || value == "nuanxia-xuanshan" ? .frame : .ink
    }
}

/// Changes the running app's Dock icon without changing the signed bundle.
/// The installation's Finder icon remains the default approved artwork.
@MainActor final class ApplicationIconController: ObservableObject {
    static let shared = ApplicationIconController()
    static let changedNotification = Notification.Name("Fangcun.applicationIcon.changed")
    static let preferenceKey = "Fangcun.applicationIcon"
    @Published private(set) var selection: ApplicationIconChoice
    @Published private(set) var error: String?

    private let defaults: UserDefaults
    private let loadImage: @MainActor (ApplicationIconChoice) -> NSImage?
    private let applyImage: @MainActor (NSImage) -> Void
    private var images: [ApplicationIconChoice: NSImage] = [:]

    init(defaults: UserDefaults = .standard,
         loadImage: @escaping @MainActor (ApplicationIconChoice) -> NSImage? = ApplicationIconController.bundleImage,
         applyImage: @escaping @MainActor (NSImage) -> Void = { NSApplication.shared.applicationIconImage = $0 }) {
        self.defaults = defaults
        self.loadImage = loadImage
        self.applyImage = applyImage
        selection = ApplicationIconChoice.restored(defaults.string(forKey: Self.preferenceKey))
    }

    func image(for choice: ApplicationIconChoice) -> NSImage? {
        if let image = images[choice] { return image }
        guard let image = loadImage(choice), image.isValid else { return nil }
        images[choice] = image
        return image
    }

    @discardableResult func select(_ choice: ApplicationIconChoice) -> Bool {
        guard let image = image(for: choice) else {
            error = "暂时无法读取“\(choice.title)”图标，原选择已保留。"
            return false
        }
        defaults.set(choice.rawValue, forKey: Self.preferenceKey)
        selection = choice
        error = nil
        applyImage(image)
        NotificationCenter.default.post(name: Self.changedNotification, object: self)
        return true
    }

    /// Called after normal application launch; test commands do not apply an icon.
    @discardableResult func applyCurrentIcon() -> Bool {
        guard let image = image(for: selection) else {
            error = "暂时无法读取应用图标。"
            return false
        }
        applyImage(image)
        NotificationCenter.default.post(name: Self.changedNotification, object: self)
        error = nil
        return true
    }

    static func menuBarImage(for choice: ApplicationIconChoice) -> NSImage? {
        guard let resource = Bundle.main.resourceURL?.appendingPathComponent("AppIcons")
            .appendingPathComponent(choice.rawValue + "-menubar.png"), let image = NSImage(contentsOf: resource) else { return nil }
        image.size = NSSize(width: 18, height: 18); image.isTemplate = true
        return image
    }
    static func bundleImage(_ choice: ApplicationIconChoice) -> NSImage? {
        guard let resource = Bundle.main.resourceURL?.appendingPathComponent("AppIcons", isDirectory: true)
            .appendingPathComponent(choice.rawValue + ".icns") else { return nil }
        return NSImage(contentsOf: resource)
    }
}
