import Foundation

/// A path is only a location. Device, inode, change time and content metadata form the identity check.
public struct SpaceCleaningFileIdentity: Codable, Equatable, Hashable, Sendable {
    public var device: UInt64
    public var inode: UInt64
    public var sizeBytes: UInt64
    public var allocatedBytes: UInt64
    public var modifiedSeconds: Int64
    public var modifiedNanoseconds: Int64
    public var changedSeconds: Int64
    public var changedNanoseconds: Int64
    public var linkCount: UInt64
    public var mode: UInt32
    public var fileKey: String { "\(device):\(inode)" }
    /// A rename may legitimately alter change time and allocation metadata.
    /// The resource, content length and modification time must remain identical.
    public func matchesMovedResource(_ other: Self) -> Bool {
        device == other.device && inode == other.inode && sizeBytes == other.sizeBytes &&
        modifiedSeconds == other.modifiedSeconds && modifiedNanoseconds == other.modifiedNanoseconds &&
        (mode & 0o170000) == (other.mode & 0o170000) && linkCount == other.linkCount
    }
}
