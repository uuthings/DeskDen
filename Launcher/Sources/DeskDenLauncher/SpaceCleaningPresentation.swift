import Foundation
import LauncherCore

enum CleaningScreen: Equatable { case start, scope, scanning, results, processing, completed, history }
enum CleaningResultGroup: String, CaseIterable, Sendable { case rebuildable, review, protected }
enum CleaningSortKey: String, CaseIterable, Sendable { case name, directory, type, modified, size }

enum CleaningScopeChoice: String, CaseIterable, Codable { case global, custom }

/// Presentation groups select existing scanner scopes without changing their policies.
enum CleaningScopeGroup: String, CaseIterable, Codable, Identifiable, Sendable {
    case downloads, documents, desktop, media, caches, development
    var id: String { rawValue }
    var title: String {
        switch self {
        case .downloads: "下载"
        case .documents: "文稿"
        case .desktop: "桌面"
        case .media: "图片与影音"
        case .caches: "应用缓存"
        case .development: "开发与归档"
        }
    }
    var symbol: String {
        switch self {
        case .downloads: "arrow.down.circle"
        case .documents: "doc.text"
        case .desktop: "desktopcomputer"
        case .media: "photo.on.rectangle"
        case .caches: "square.3.layers.3d"
        case .development: "chevron.left.forwardslash.chevron.right"
        }
    }
    var summary: String {
        switch self {
        case .downloads: "安装包、归档与下载文件"
        case .documents: "文档、资料与工作文件"
        case .desktop: "桌面文件与临时整理"
        case .media: "照片、音乐与视频资料"
        case .caches: "应用产生的可重建内容"
        case .development: "构建产物与归档内容"
        }
    }
    var detailPaths: [String] {
        switch self {
        case .downloads: ["~/Downloads"]
        case .documents: ["~/Documents", "~/Public"]
        case .desktop: ["~/Desktop"]
        case .media: ["~/Pictures", "~/Music", "~/Movies"]
        case .caches: ["~/Library/Caches", "~/Library/Containers/com.apple.Safari/Data/Library/Caches", "~/.npm/_cacache", "~/Library/Logs/DiagnosticReports"]
        case .development: ["~/Developer", "~/Library/Developer/Xcode/DerivedData", "~/Library/Developer/Xcode/Archives", "~/Applications", "~/Library/Application Support 内的发布档案", "已登记的发布档案位置"]
        }
    }
    var pathDescription: String { detailPaths.joined(separator: " · ") }
    var content: String {
        switch self {
        case .downloads: "检查下载目录中的文件与子目录，按实际体积呈现。"
        case .documents: "检查文稿与公共目录，保留层级供你核对文档、资料和归档。"
        case .desktop: "检查桌面上的文件与目录，保留原始路径供你核对。"
        case .media: "检查用户媒体目录中的照片、视频、音频与归档。"
        case .caches: "识别已知应用缓存、包下载缓存和诊断记录，显示具体文件与判断依据。"
        case .development: "检查开发目录、构建缓存、用户应用及归档，发布档案只核验保护状态。"
        }
    }
    var impact: String {
        switch self {
        case .downloads: "下载时间与文件体积只作参考，处理前由你逐项确认。"
        case .documents: "不因文件较旧或体积较大而自动判断为可清理。"
        case .desktop: "先确认文件用途与归属，再选择移入废纸篓或保留。"
        case .media: "不自动推断哪些媒体资料已经不再需要。"
        case .caches: "仅完整核验的可重建缓存可预选，部分内容会重新下载。"
        case .development: "Git 资料、依赖、虚拟环境、已安装应用及发布原件保持保护。"
        }
    }
    func includes(_ scope: SpaceCleaningScope, home: URL) -> Bool {
        switch scope.kind {
        case .downloads: return self == .downloads
        case .browserCache, .packageCache, .diagnostics: return self == .caches
        case .derivedData, .development, .archives, .releaseArchives, .releaseArchiveDiscovery, .installedApplications:
            return self == .development
        case .custom:
            let root = SpaceCleaningScanner.canonicalURL(home) ?? home.standardizedFileURL
            let names: [String]
            switch self {
            case .documents: names = ["Documents", "Public"]
            case .desktop: names = ["Desktop"]
            case .media: names = ["Pictures", "Music", "Movies"]
            case .development: names = ["Developer"]
            case .downloads, .caches: names = []
            }
            return names.contains { root.appendingPathComponent($0).standardizedFileURL == scope.directory.standardizedFileURL }
        }
    }
}
enum CleaningResultTab: Sendable { case recommended, reviewable, protected }
enum CleaningFileSizeUnit: String, Codable, CaseIterable {
    case mb = "MB", gb = "GB"
    var bytes: Double { self == .mb ? 1_000_000 : 1_000_000_000 }
}

struct CleaningItemDisplay: Identifiable, Sendable {
    let id: UUID
    let name: String
    let url: URL
    let bytes: UInt64
    var allocatedBytes: UInt64 = 0
    let sizeIsComplete: Bool
    let group: CleaningResultGroup
    let subtitle: String
    let reason: String
    let impact: String
    let isSelectable: Bool
    let needsPurposeConfirmation: Bool
    let kind: SpaceCleaningKind
    let isDirectory: Bool
    let modifiedDate: Date

    var fileCategory: CleaningFileCategory { .init(url: url, isDirectory: isDirectory) }
    var typeTitle: String { fileCategory.title(forExtension: url.pathExtension) }
    /// Personal-file rows already carry their useful facts. Only show an
    /// explanation when a scan rule actually changes the available action.
    var handlingNote: String? {
        if group == .protected || group == .rebuildable || needsPurposeConfirmation || [.testApplication, .testArchive, .installerPackage, .downloadedDiskImage, .oldDiagnostic].contains(kind) {
            return reason + " " + impact
        }
        return nil
    }
    var needsSuggestionReview: Bool {
        isSelectable && [.installerPackage, .downloadedDiskImage, .oldDiagnostic].contains(kind)
    }
    var protectionTitle: String? {
        guard group == .protected else { return nil }
        if kind == .developmentEnvironment { return "开发环境" }
        if needsPurposeConfirmation { return "可确认用途" }
        if !sizeIsComplete { return "核验未完成" }
        switch kind {
        case .releaseArchive, .releaseMaterial: return "发布材料"
        case .runningApplication: return "正在使用"
        case .installedApplication: return "已安装应用"
        case .cloudPlaceholder: return "云端占位"
        default: return "保持保留"
        }
    }
    var protectionGuidance: String? {
        guard group == .protected else { return nil }
        if kind == .developmentEnvironment { return "清理扫描不展开依赖与版本资料。可单独统计占用，统计后仍保持保护，不提供内部文件清理。" }
        if needsPurposeConfirmation { return "若这是本地测试副本，可点「确认测试用途」。重新核验通过后会移到其他文件，由你勾选。" }
        if !sizeIsComplete { return "当前未完成内容核验，不能解除保护；可缩小扫描范围后重新检查。" }
        switch kind {
        case .releaseArchive, .releaseMaterial: return "发布原件及关联材料在清理中保持保护，不提供一键解除；签名或公证本身不是这条保护规则的依据。"
        case .runningApplication: return "退出相关应用或结束构建后重新扫描，使用状态解除后会重新判断。"
        case .installedApplication: return "这是已安装应用，不能通过空间清理解除保护；如需移除，应使用应用卸载流程。"
        case .unknownApplication, .unknownArchive: return "包内容未通过测试副本核验，当前不能解除保护。"
        default: return "这类内容不提供直接解除保护；具体原因以上方说明为准。"
        }
    }
}

/// Classify scanned metadata only. Scrolling never asks Finder for a file icon
/// or opens a file to determine its type.
enum CleaningFileCategory: String, Sendable, CaseIterable {
    case folder, application, xcodeArchive, diskImage, installer, archive, pdf, document, image, video, audio, code, file

    init(url: URL, isDirectory: Bool) {
        let ext = url.pathExtension.lowercased()
        if isDirectory {
            self = ext == "app" ? .application : ext == "xcarchive" ? .xcodeArchive : .folder
            return
        }
        switch ext {
        case "dmg", "iso": self = .diskImage
        case "pkg", "mpkg": self = .installer
        case "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar": self = .archive
        case "pdf": self = .pdf
        case "txt", "md", "rtf", "doc", "docx", "pages", "xls", "xlsx", "csv", "numbers", "ppt", "pptx", "key": self = .document
        case "jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "tif", "tiff", "svg", "raw": self = .image
        case "mov", "mp4", "m4v", "mkv", "avi", "webm": self = .video
        case "mp3", "m4a", "aac", "wav", "aiff", "flac", "ogg": self = .audio
        case "swift", "m", "mm", "h", "c", "cpp", "rs", "go", "py", "js", "jsx", "ts", "tsx", "html", "css", "json", "yaml", "yml", "toml", "sh": self = .code
        default: self = .file
        }
    }
    var symbol: String {
        switch self {
        case .folder: "folder"
        case .application: "app.dashed"
        case .xcodeArchive: "archivebox"
        case .diskImage: "externaldrive"
        case .installer: "shippingbox"
        case .archive: "doc.zipper"
        case .pdf, .document: "doc.text"
        case .image: "photo"
        case .video: "film"
        case .audio: "waveform"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .file: "doc"
        }
    }
    func title(forExtension ext: String) -> String {
        let prefix = ext.isEmpty ? "" : ext.uppercased() + " "
        switch self {
        case .folder: return "文件夹"
        case .application: return "应用程序"
        case .xcodeArchive: return "Xcode 归档"
        case .diskImage: return prefix + "磁盘映像"
        case .installer: return prefix + "安装包"
        case .archive: return prefix + "压缩包"
        case .pdf, .document: return prefix + "文档"
        case .image: return prefix + "图片"
        case .video: return prefix + "视频"
        case .audio: return prefix + "音频"
        case .code: return prefix + "代码"
        case .file: return prefix + "文件"
        }
    }
}

struct CleaningHistoryItemDisplay: Identifiable, Sendable {
    let id: UUID
    let name: String
    let bytes: UInt64
    var allocatedBytes: UInt64 = 0
    let state: SpaceCleaningRecordState
    let statusText: String
    let explanation: String
    let canRestore: Bool
    let canPurge: Bool
    let originalURL: URL
    let resultURL: URL?
    var isDirectory: Bool? = nil
}

struct CleaningHistoryBatchDisplay: Identifiable, Sendable {
    let id: UUID
    let date: Date
    let method: SpaceCleaningMethod
    let items: [CleaningHistoryItemDisplay]
    let bytes: UInt64
    var allocatedBytes: UInt64 { items.reduce(0) { $0 &+ $1.allocatedBytes } }
    var successfulAllocatedBytes: UInt64 { items.filter { [.trashed, .deleted].contains($0.state) }.reduce(0) { $0 &+ $1.allocatedBytes } }
    var deletedCount: Int { items.filter { $0.state == .deleted }.count }
    var attentionCount: Int { items.filter { [.failed, .needsReview, .prepared, .isolated, .deleting, .restoring].contains($0.state) }.count }
    var restorableCount: Int { items.filter(\.canRestore).count }
    var purgeableCount: Int { items.filter(\.canPurge).count }
}

enum CleaningDialog: Identifiable, Equatable {
    case scope, rules, confirm, purpose(UUID), restore(UUID), purge(UUID), issues
    var id: String {
        switch self {
        case .scope: "scope"
        case .rules: "rules"
        case .confirm: "confirm"
        case .purpose(let id): "purpose-\(id)"
        case .restore(let id): "restore-\(id)"
        case .purge(let id): "purge-\(id)"
        case .issues: "issues"
        }
    }
}
