import Foundation
import Darwin

/// Durable history of cleaning intentions and outcomes.
///
/// `history.json` stays a complete snapshot that earlier releases can read.
/// Every persist appends one full record as a JSON line to `history.journal`
/// and syncs it, so a write costs one record instead of the whole history.
/// Once the journal is as large as the snapshot, the snapshot is rewritten and
/// the journal emptied. Loading merges both by `updatedAt`, which keeps an
/// interrupted compaction, or a snapshot rewritten by an earlier release,
/// consistent. Batches that have fully finished move to an append-only
/// archive beside the history once the live limit is reached; recoverable
/// and uncertain records always stay live. Invalid or externally modified
/// files block mutation and are never silently replaced.
public final class SpaceCleaningHistoryStore: @unchecked Sendable {
    struct Limits: Sendable {
        var liveRecords = 10_000
        /// Archiving keeps this many live records so it does not run on every write.
        var archiveTarget = 8_000
        var snapshotBytes = 33_554_432
        /// Above this encoded size, finished batches are archived before compaction.
        var liveSnapshotBytes = 25_165_824
        var journalBytes = 67_108_864
        var compactionBytes = 2_097_152
        static let production = Limits()
    }
    private static let finishedStates: Set<SpaceCleaningRecordState> = [.deleted, .restored, .skipped, .cancelled, .failed]
    private typealias Directory = SpaceCleaningFilesystem.Directory

    private let fileURL: URL
    private let journalURL: URL
    private let archiveURL: URL
    private let limits: Limits
    private let lock = NSLock()
    private var values: [UUID: SpaceCleaningRecord] = [:]
    private var fileIdentity: SpaceCleaningFileIdentity?
    private var snapshotBytes = 0
    /// Device and inode of the journal this store last read or wrote.
    private var journalFile: FileKey?
    /// Bytes of complete journal lines, and the file length including any torn tail.
    private var journalBytes = 0
    private var journalLength = 0
    private struct FileKey: Equatable { var device: UInt64; var inode: UInt64 }

    public convenience init(fileURL: URL) throws { try self.init(fileURL: fileURL, limits: .production) }

    init(fileURL: URL, limits: Limits) throws {
        guard fileURL.isFileURL else { throw Self.failure("清理记录位置无效。") }
        self.fileURL = fileURL; self.limits = limits
        let directory = fileURL.deletingLastPathComponent(), stem = fileURL.deletingPathExtension().lastPathComponent
        journalURL = directory.appendingPathComponent(stem + ".journal", isDirectory: false)
        archiveURL = directory.appendingPathComponent(stem + "-archive.jsonl", isDirectory: false)
        if !SpaceCleaningFilesystem.absent(fileURL) {
            let (data, info) = try Self.readPrivateFile(fileURL, limit: limits.snapshotBytes, unreadable: "清理记录无法读取，暂停文件处理。")
            let records = try JSONDecoder().decode([SpaceCleaningRecord].self, from: data)
            guard records.count <= limits.liveRecords, Set(records.map(\.id)).count == records.count else {
                throw Self.failure("清理记录重复或超过容量。")
            }
            for record in records { values[record.id] = try record.validated() }
            fileIdentity = SpaceCleaningFilesystem.identity(info); snapshotBytes = data.count
            guard SpaceCleaningFilesystem.capture(fileURL) == fileIdentity else { throw Self.failure("读取期间清理记录已变化。") }
        }
        if !SpaceCleaningFilesystem.absent(journalURL) {
            let (data, info) = try Self.readPrivateFile(journalURL, limit: limits.journalBytes, unreadable: "清理记录日志无法读取，暂停文件处理。")
            let decoder = JSONDecoder()
            var start = data.startIndex
            while let end = data[start...].firstIndex(of: 0x0A) {
                // Any complete line that does not decode is corruption, not a torn write.
                let record = try decoder.decode(SpaceCleaningRecord.self, from: data[start..<end]).validated()
                start = data.index(after: end)
                if let current = values[record.id], current.updatedAt > record.updatedAt { continue }
                values[record.id] = record
            }
            let key = FileKey(device: UInt64(bitPattern: Int64(info.st_dev)), inode: UInt64(info.st_ino))
            journalFile = key
            journalBytes = data.distance(from: data.startIndex, to: start); journalLength = data.count
            guard let current = SpaceCleaningFilesystem.capture(journalURL), current.device == key.device,
                  current.inode == key.inode, Int(current.sizeBytes) == journalLength else {
                throw Self.failure("读取期间清理记录已变化。")
            }
        }
    }

    public var records: [SpaceCleaningRecord] {
        lock.lock(); defer { lock.unlock() }; return values.values.sorted { $0.createdAt > $1.createdAt }
    }

    public func record(_ value: SpaceCleaningRecord) throws {
        lock.lock(); defer { lock.unlock() }
        let checked = try value.validated()
        let parent = try openDirectory()
        guard parent.entry(fileURL.lastPathComponent) == fileIdentity else { throw Self.failure("清理记录被外部修改，原记录已保留。") }
        if values[checked.id] == nil, values.count + 1 > limits.liveRecords {
            try archiveFinishedBatches(parent, keeping: limits.archiveTarget)
            guard values.count + 1 <= limits.liveRecords else {
                throw Self.failure("可恢复或待核对的清理记录已达上限，请先恢复或永久删除部分项目后再处理。")
            }
        }
        var line = try JSONEncoder().encode(checked)
        line.append(0x0A)
        try appendJournal(line, parent: parent)
        values[checked.id] = checked
        // The record is already durable in the journal; a failed compaction only
        // postpones the rewrite, and the next write re-checks every file.
        if journalBytes >= max(limits.compactionBytes, snapshotBytes) { try? compact(parent) }
    }

    // MARK: - Files

    private static func failure(_ message: String) -> SpaceCleaningFilesystem.Failure { .init(message: message) }

    private static func readPrivateFile(_ url: URL, limit: Int, unreadable: String) throws -> (Data, stat) {
        let descriptor = url.withUnsafeFileSystemRepresentation { $0.map { open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY | O_NONBLOCK) } ?? -1 }
        guard descriptor >= 0 else { throw failure(unreadable) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_uid == getuid(), info.st_size <= limit else { throw failure("清理记录不是有效的私有文件。") }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw failure("清理记录超过安全容量。") }
        return (data, info)
    }

    private func openDirectory() throws -> Directory {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let parent = try Directory(fileURL.deletingLastPathComponent())
        guard parent.stillAtPath() else { throw Self.failure("清理记录位置已变化。") }
        return parent
    }

    private static func write(_ data: Data, to descriptor: Int32, at offset: Int) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var written = 0
            while written < bytes.count {
                let count = pwrite(descriptor, base.advanced(by: written), bytes.count - written, off_t(offset + written))
                if count < 0 { if errno == EINTR { continue }; throw failure("处理意图未完整写入。") }
                guard count > 0 else { throw failure("处理意图写入中断。") }
                written += count
            }
        }
    }

    private static func openPrivate(_ name: String, in parent: Directory, flags: Int32) throws -> (Int32, stat) {
        let descriptor = name.withCString { openat(parent.descriptor, $0, flags | O_CLOEXEC | O_NOFOLLOW, 0o600) }
        guard descriptor >= 0 else { throw failure("无法写入处理记录，未操作文件。") }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_uid == getuid() else {
            close(descriptor); throw failure("清理记录不是有效的私有文件。")
        }
        return (descriptor, info)
    }

    private func appendJournal(_ line: Data, parent: Directory) throws {
        let name = journalURL.lastPathComponent
        let (descriptor, info) = try Self.openPrivate(name, in: parent, flags: O_WRONLY | O_CREAT)
        defer { close(descriptor) }
        let key = FileKey(device: UInt64(bitPattern: Int64(info.st_dev)), inode: UInt64(info.st_ino))
        if let expected = journalFile {
            guard key == expected, Int(info.st_size) == journalLength else { throw Self.failure("清理记录被外部修改，原记录已保留。") }
        } else {
            guard info.st_size == 0 else { throw Self.failure("清理记录被外部修改，原记录已保留。") }
            journalFile = key; journalBytes = 0; journalLength = 0
        }
        // An interrupted append left a partial line that was never acknowledged.
        if journalLength != journalBytes {
            guard ftruncate(descriptor, off_t(journalBytes)) == 0 else { throw Self.failure("处理记录日志无法清除未完成的写入。") }
            journalLength = journalBytes
        }
        do { try Self.write(line, to: descriptor, at: journalBytes) }
        catch {
            var after = stat()
            if fstat(descriptor, &after) == 0 { journalLength = Int(after.st_size) }
            throw error
        }
        journalLength = journalBytes + line.count
        guard fsync(descriptor) == 0, parent.stillAtPath(), let current = parent.entry(name),
              current.device == key.device, current.inode == key.inode else {
            throw Self.failure("处理记录未安全落盘或被外部修改。")
        }
        journalBytes = journalLength
    }

    private func resetJournal(_ parent: Directory) throws {
        guard let expected = journalFile else { return }
        let (descriptor, info) = try Self.openPrivate(journalURL.lastPathComponent, in: parent, flags: O_WRONLY)
        defer { close(descriptor) }
        guard FileKey(device: UInt64(bitPattern: Int64(info.st_dev)), inode: UInt64(info.st_ino)) == expected,
              Int(info.st_size) == journalLength else { throw Self.failure("清理记录被外部修改，原记录已保留。") }
        guard ftruncate(descriptor, 0) == 0, fsync(descriptor) == 0 else { throw Self.failure("处理记录日志无法整理。") }
        journalBytes = 0; journalLength = 0
    }

    private func replaceSnapshot(with data: Data, parent: Directory) throws {
        guard parent.entry(fileURL.lastPathComponent) == fileIdentity else { throw Self.failure("清理记录被外部修改，原记录已保留。") }
        let temporary = ".space-cleaning-journal-" + UUID().uuidString
        let descriptor = temporary.withCString { openat(parent.descriptor, $0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600) }
        guard descriptor >= 0 else { throw Self.failure("无法写入处理意图，未操作文件。") }
        defer { close(descriptor); _ = temporary.withCString { unlinkat(parent.descriptor, $0, 0) } }
        try Self.write(data, to: descriptor, at: 0)
        guard fsync(descriptor) == 0, parent.stillAtPath(), parent.entry(fileURL.lastPathComponent) == fileIdentity else {
            throw Self.failure("处理记录未安全落盘或被外部修改。")
        }
        let result = temporary.withCString { from in fileURL.lastPathComponent.withCString { to in
            fileIdentity == nil ? renameatx_np(parent.descriptor, from, parent.descriptor, to, UInt32(RENAME_EXCL))
                : renameat(parent.descriptor, from, parent.descriptor, to)
        } }
        guard result == 0 else { throw Self.failure("处理记录无法原子保存。") }
        fileIdentity = parent.entry(fileURL.lastPathComponent)
        guard fileIdentity != nil, parent.stillAtPath() else { throw Self.failure("保存后的处理记录无法核验。") }
        snapshotBytes = data.count
    }

    private func encodedSnapshot() throws -> Data {
        try JSONEncoder().encode(values.values.sorted { $0.createdAt < $1.createdAt })
    }

    /// Rewrites the snapshot from the live records and empties the journal. A
    /// crash in between leaves journal lines that merge idempotently on load.
    private func compact(_ parent: Directory) throws {
        let data = try encodedSnapshot()
        if data.count > limits.liveSnapshotBytes, !values.isEmpty {
            let target = Int(Double(values.count) * Double(limits.liveSnapshotBytes) / Double(data.count) * 0.9)
            if try archiveFinishedBatches(parent, keeping: min(limits.archiveTarget, target)) > 0 { return }
        }
        guard data.count <= limits.snapshotBytes else { throw Self.failure("清理历史已达容量上限，停止新处理。") }
        try replaceSnapshot(with: data, parent: parent)
        try resetJournal(parent)
    }

    /// Moves the oldest batches whose records have all finished to the archive,
    /// then compacts. Batches with a recoverable or uncertain record stay live.
    @discardableResult
    private func archiveFinishedBatches(_ parent: Directory, keeping target: Int) throws -> Int {
        let finished = Dictionary(grouping: values.values, by: \.operationID)
            .filter { $0.value.allSatisfy { Self.finishedStates.contains($0.state) } }
            .map { (start: $0.value.map(\.createdAt).min() ?? .distantPast, records: $0.value) }
            .sorted { $0.start < $1.start }
        var remaining = values.count, selected: [SpaceCleaningRecord] = []
        for batch in finished where remaining > target {
            selected += batch.records; remaining -= batch.records.count
        }
        guard !selected.isEmpty else { return 0 }
        var lines = Data()
        let encoder = JSONEncoder()
        for record in selected.sorted(by: { $0.createdAt < $1.createdAt }) { lines.append(try encoder.encode(record)); lines.append(0x0A) }
        try appendArchive(lines, parent: parent)
        let previous = values
        for record in selected { values.removeValue(forKey: record.id) }
        do {
            let data = try encodedSnapshot()
            guard data.count <= limits.snapshotBytes else { throw Self.failure("清理历史已达容量上限，停止新处理。") }
            try replaceSnapshot(with: data, parent: parent)
            try resetJournal(parent)
        } catch { values = previous; throw error }
        return selected.count
    }

    /// The archive is append-only and never loaded; duplicates after an
    /// interrupted archive step are harmless.
    private func appendArchive(_ lines: Data, parent: Directory) throws {
        let (descriptor, info) = try Self.openPrivate(archiveURL.lastPathComponent, in: parent, flags: O_WRONLY | O_CREAT)
        defer { close(descriptor) }
        var offset = Int(info.st_size)
        if offset > 0 {
            var last: UInt8 = 0
            if pread(descriptor, &last, 1, off_t(offset - 1)) == 1, last != 0x0A {
                try Self.write(Data([0x0A]), to: descriptor, at: offset); offset += 1
            }
        }
        try Self.write(lines, to: descriptor, at: offset)
        guard fsync(descriptor) == 0 else { throw Self.failure("处理记录归档未安全落盘。") }
    }
}
