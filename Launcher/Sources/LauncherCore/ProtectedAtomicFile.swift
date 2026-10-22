import Foundation
import Darwin

/// The private temporary file is completely written before a single atomic
/// rename. An error cannot mean “new bytes are on disk, old values in memory”.
public enum ProtectedAtomicFile {
    public static func write(_ data:Data,to url:URL) throws {
        guard url.isFileURL else {throw CocoaError(.fileWriteUnsupportedScheme)}
        let manager=FileManager.default,parent=url.deletingLastPathComponent()
        try manager.createDirectory(at:parent,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let temporary=parent.appendingPathComponent(".fangcun-save-\(UUID().uuidString)")
        guard manager.createFile(atPath:temporary.path,contents:nil,attributes:[.posixPermissions:0o600]) else {throw CocoaError(.fileWriteNoPermission)}
        defer {try? manager.removeItem(at:temporary)}
        let handle=try FileHandle(forWritingTo:temporary)
        do {try handle.write(contentsOf:data);try handle.synchronize();try handle.close()}
        catch {try? handle.close();throw error}
        guard Darwin.rename(temporary.path,url.path) == 0 else {throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO)}
    }
}
