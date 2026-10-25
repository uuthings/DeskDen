import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A conservative boundary, never proof that a development environment is disposable.
/// Only fixed marker paths are inspected; dependency contents and links are not followed.
enum SpaceCleaningDevelopmentPolicy {
    static func reason(at url: URL) -> String? {
        var lookup = Lookup()
        return lookup.reason(at: url)
    }

    /// The transaction already obtained a bounded, no-follow content snapshot.
    /// Reuse its metadata to apply today's protection to old aggregate receipts.
    static func reason(in snapshot: SpaceCleaningFilesystem.Snapshot) -> String? {
        for node in snapshot.nodes {
            let components = node.path.split(separator: "/")
            if components.contains(where: { namedReason(String($0)) != nil }) {
                return "所选目录包含开发依赖或版本资料，保留整个项目。"
            }
            if components.last == "pyvenv.cfg", node.identity.mode & UInt32(S_IFMT) == UInt32(S_IFREG) {
                return "所选目录包含 Python 虚拟环境标记，保留整个项目。"
            }
        }
        return nil
    }

    /// This cache belongs to one read-only scan. Processing and receipt policies
    /// create a fresh lookup, so a newly added environment marker revokes deletion.
    struct Lookup {
        private struct Verdict { var reason: String? }
        private var directories: [String: Verdict] = [:]
        init() {}
        mutating func reason(at url: URL, identity: StorageReviewFileIdentity? = nil) -> String? {
            guard url.isFileURL else { return nil }
            if let reason = SpaceCleaningDevelopmentPolicy.namedReason(url.lastPathComponent) { return reason }
            if let verdict = directories[url.path] { return verdict.reason }
            let identity = identity ?? SpaceCleaningScanner.captureIdentity(at: url)
            let isDirectory = identity.map { $0.mode & UInt32(S_IFMT) == UInt32(S_IFDIR) } ?? false
            // Preserve the scanner's canonical path. standardizedFileURL rewrites
            // /private/var to /var on macOS and would invalidate the no-link check.
            var current = isDirectory ? url : url.deletingLastPathComponent()
            var pending: [String] = []
            var result: String?
            while current.path != "/" {
                if let verdict = directories[current.path] { result = verdict.reason; break }
                pending.append(current.path)
                if let reason = SpaceCleaningDevelopmentPolicy.namedReason(current.lastPathComponent) { result = reason; break }
                if let value = SpaceCleaningScanner.captureIdentity(at: current),
                   value.mode & UInt32(S_IFMT) == UInt32(S_IFDIR),
                   SpaceCleaningScanner.canonicalURL(current)?.path == current.path,
                   let marker = SpaceCleaningScanner.captureIdentity(at: current.appendingPathComponent("pyvenv.cfg")),
                   marker.mode & UInt32(S_IFMT) == UInt32(S_IFREG) {
                    result = "此目录含有 Python 虚拟环境标记，保留整个环境。"; break
                }
                current.deleteLastPathComponent()
            }
            for path in pending { directories[path] = Verdict(reason: result) }
            return result
        }
    }

    private static func namedReason(_ name: String) -> String? {
        switch name.lowercased() {
        case ".git": "Git 版本资料，保留整个目录及其内容。"
        case "node_modules", "bower_components", "__pypackages__": "开发依赖或同名目录，默认保留，不展开内部文件。"
        case ".venv", "venv": "Python 环境或同名目录，默认保留，不展开内部文件。"
        default: nil
        }
    }
}
