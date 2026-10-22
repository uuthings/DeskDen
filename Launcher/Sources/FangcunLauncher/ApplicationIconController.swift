import AppKit
import Combine
import Foundation

enum ApplicationIconChoice: String, CaseIterable, Identifiable {
    case qingbiChenwu = "qingbi-chenwu"
    case yuebaiYunhai = "yuebai-yunhai"
    case nuanxiaXuanshan = "nuanxia-xuanshan"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .qingbiChenwu: "青碧晨雾"
        case .yuebaiYunhai: "月白云海"
        case .nuanxiaXuanshan: "暖霞悬山"
        }
    }
    var subtitle: String {
        switch self {
        case .qingbiChenwu: "晨光入山 · 清透青碧"
        case .yuebaiYunhai: "月色照山 · 银蓝云海"
        case .nuanxiaXuanshan: "暖霞映山 · 云间仙境"
        }
    }
}

/// Changes the running app's Dock icon without changing the signed bundle.
/// The installation's Finder icon remains the default approved artwork.
@MainActor final class ApplicationIconController: ObservableObject {
    static let shared = ApplicationIconController()
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
        selection = defaults.string(forKey: Self.preferenceKey).flatMap(ApplicationIconChoice.init(rawValue:)) ?? .qingbiChenwu
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
        return true
    }

    /// Called after normal application launch; test commands do not apply an icon.
    @discardableResult func applyCurrentIcon() -> Bool {
        guard let image = image(for: selection) else {
            error = "暂时无法读取应用图标。"
            return false
        }
        applyImage(image)
        error = nil
        return true
    }

    static func bundleImage(_ choice: ApplicationIconChoice) -> NSImage? {
        guard let resource = Bundle.main.resourceURL?.appendingPathComponent("AppIcons", isDirectory: true)
            .appendingPathComponent(choice.rawValue + ".icns") else { return nil }
        return NSImage(contentsOf: resource)
    }
}
