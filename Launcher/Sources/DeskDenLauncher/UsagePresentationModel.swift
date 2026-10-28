import AppKit
import Combine
import Darwin
import ImageIO
import LauncherCore
import UniformTypeIdentifiers

/// Only presentation metadata and normalized icon copies live in this directory.
/// This model neither enables collectors nor reads service credentials.
@MainActor final class UsagePresentationModel: ObservableObject {
    @Published private(set) var preferences = UsagePresentationPreferences()
    @Published var errorMessage: String?
    @Published private(set) var storageError: String?
    private let store: UsagePresentationStore
    private let iconDirectory: URL
    private let cache = NSCache<NSString, NSImage>()
    static let maximumImportBytes = 2_097_152
    static let maximumStoredImageBytes = 524_288
    static let maximumPixelDimension = 8_192
    static let maximumPixelCount = 40_000_000

    init(dataDirectory: URL) {
        store = UsagePresentationStore(url: dataDirectory.appendingPathComponent("display-preferences.json"))
        iconDirectory = dataDirectory.appendingPathComponent("Icons", isDirectory: true)
        cache.countLimit = 32; cache.totalCostLimit = 8_388_608
        do { preferences = try store.load(); removeUnreferencedIcons() }
        catch { storageError = "用量显示设置无法读取，原文件已保留；修复前暂停修改。" }
    }

    func isCollapsed(_ group: UsageCardGroup) -> Bool { preferences.isCollapsed(group) }
    func appearance(for key: String) -> UsageCardAppearance { preferences.cards[key] ?? .init() }

    @discardableResult func setCollapsed(_ value: Bool, group: UsageCardGroup) -> Bool {
        var next = preferences; next.setCollapsed(value, group: group); return persist(next)
    }
    @discardableResult func setVisible(_ visible: Bool, for key: String) -> Bool {
        var value = appearance(for: key); value.visible = visible; return saveAppearance(value, for: key)
    }
    @discardableResult func saveAppearance(_ value: UsageCardAppearance, for key: String) -> Bool {
        var normalized = value
        normalized.displayName = value.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.displayName?.isEmpty == true { normalized.displayName = nil }
        var next = preferences; next.cards[key] = normalized
        return persist(next)
    }
    @discardableResult func removeAppearance(for key: String) -> Bool {
        var next = preferences; next.cards.removeValue(forKey: key); return persist(next)
    }
    private func persist(_ next: UsagePresentationPreferences) -> Bool {
        guard storageError == nil else { errorMessage = storageError; return false }
        do { try store.save(next); preferences = next; errorMessage = nil; return true }
        catch let error as UsagePresentationError { errorMessage = error.localizedDescription; return false }
        catch { errorMessage = UsagePresentationError.storage.localizedDescription; return false }
    }

    func chooseImage(completion: @escaping @MainActor (UsageCardIcon) -> Void) {
        guard storageError == nil else { errorMessage = storageError; return }
        let panel = NSOpenPanel(); panel.title = "选择卡片图标"
        panel.allowedContentTypes = [.png, .jpeg, .webP]; panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.begin { [weak self] response in
            Task { @MainActor in
                guard let self, response == .OK, let url = panel.url else { return }
                do { completion(try self.importImage(from: url)); self.errorMessage = nil }
                catch let error as UsagePresentationError { self.errorMessage = error.localizedDescription }
                catch { self.errorMessage = UsagePresentationError.image.localizedDescription }
            }
        }
    }

    /// Called only after an explicit picker choice. The bounded read and thumbnail
    /// avoid retaining a full-size original or its metadata in app preferences.
    func importImage(from url: URL) throws -> UsageCardIcon {
        guard storageError == nil else { throw UsagePresentationError.storage }
        let data = try Self.readImageData(at: url, maximumBytes: Self.maximumImportBytes)
        guard
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?,
              [UTType.png.identifier, UTType.jpeg.identifier, UTType.webP.identifier].contains(type),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else { throw UsagePresentationError.image }
        let w = width.intValue, h = height.intValue
        guard w > 0, h > 0, w <= Self.maximumPixelDimension, h <= Self.maximumPixelDimension,
              w <= Self.maximumPixelCount / h,
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: false,
                kCGImageSourceThumbnailMaxPixelSize: 256
              ] as CFDictionary) else { throw UsagePresentationError.image }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { throw UsagePresentationError.image }
        CGImageDestinationAddImage(destination, thumbnail, nil)
        guard CGImageDestinationFinalize(destination), output.length <= Self.maximumStoredImageBytes else { throw UsagePresentationError.image }
        try prepareIconDirectory()
        let existing = try FileManager.default.contentsOfDirectory(at: iconDirectory, includingPropertiesForKeys: nil)
        guard existing.count < 256 else { throw UsagePresentationError.storage }
        let name = UUID().uuidString.lowercased() + ".png"
        let target = iconDirectory.appendingPathComponent(name)
        try (output as Data).write(to: target, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        let image = NSImage(cgImage: thumbnail, size: NSSize(width: CGFloat(thumbnail.width), height: CGFloat(thumbnail.height)))
        cache.setObject(image, forKey: name as NSString, cost: thumbnail.width * thumbnail.height * 4)
        return .image(name)
    }

    func image(for icon: UsageCardIcon) -> NSImage? {
        guard case .image(let name) = icon, UsageCardIcon.isManagedImageName(name) else { return nil }
        if let existing = cache.object(forKey: name as NSString) { return existing }
        let manager = FileManager.default
        let url = iconDirectory.appendingPathComponent(name)
        guard (try? manager.attributesOfItem(atPath: iconDirectory.path)[.type]) as? FileAttributeType == .typeDirectory,
              (try? manager.attributesOfItem(atPath: iconDirectory.deletingLastPathComponent().path)[.type]) as? FileAttributeType == .typeDirectory,
              let data = try? Self.readImageData(at: url, maximumBytes: Self.maximumStoredImageBytes),
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) as String? == UTType.png.identifier,
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              (1...256).contains(width.intValue), (1...256).contains(height.intValue),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 256
              ] as CFDictionary) else { return nil }
        let image = NSImage(cgImage: thumbnail, size: NSSize(width: CGFloat(thumbnail.width), height: CGFloat(thumbnail.height)))
        cache.setObject(image, forKey: name as NSString, cost: thumbnail.width * thumbnail.height * 4)
        return image
    }

    private static func readImageData(at url: URL, maximumBytes: Int) throws -> Data {
        guard url.isFileURL, url.host.map({ $0.isEmpty || $0 == "localhost" }) ?? true else { throw UsagePresentationError.image }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw UsagePresentationError.image }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size > 0, info.st_size <= maximumBytes else { throw UsagePresentationError.image }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard !data.isEmpty, data.count <= maximumBytes else { throw UsagePresentationError.image }
        return data
    }

    private func prepareIconDirectory() throws {
        let manager = FileManager.default
        try manager.createDirectory(at: iconDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard try manager.attributesOfItem(atPath: iconDirectory.path)[.type] as? FileAttributeType == .typeDirectory,
              try manager.attributesOfItem(atPath: iconDirectory.deletingLastPathComponent().path)[.type] as? FileAttributeType == .typeDirectory else { throw UsagePresentationError.storage }
    }

    private func removeUnreferencedIcons() {
        let manager = FileManager.default
        guard (try? manager.attributesOfItem(atPath: iconDirectory.path)[.type]) as? FileAttributeType == .typeDirectory,
              let urls = try? manager.contentsOfDirectory(at: iconDirectory, includingPropertiesForKeys: nil) else { return }
        let retained = Set(preferences.cards.values.compactMap { value -> String? in
            if case .image(let name) = value.icon { return name }; return nil
        })
        for url in urls where UsageCardIcon.isManagedImageName(url.lastPathComponent) && !retained.contains(url.lastPathComponent) {
            guard (try? manager.attributesOfItem(atPath: url.path)[.type]) as? FileAttributeType == .typeRegular else { continue }
            try? manager.removeItem(at: url)
        }
    }
}
