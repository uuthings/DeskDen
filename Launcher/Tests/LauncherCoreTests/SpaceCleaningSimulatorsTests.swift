import XCTest
@testable import LauncherCore

/// Deletes the device folder the way `simctl delete` does, and never trashes.
private final class SimulatorMover: SpaceCleaningFileOperating, @unchecked Sendable {
    enum Behavior { case delete, failWithoutChange, succeedWithoutChange, deleteThenFail }
    let devices: URL
    let behavior: Behavior
    private let lock = NSLock()
    private var deletedValues: [String] = []
    init(devices: URL, behavior: Behavior = .delete) { self.devices = devices; self.behavior = behavior }
    var deleted: [String] { lock.lock(); defer { lock.unlock() }; return deletedValues }
    func moveToTrash(_ source: URL) throws -> URL {
        XCTFail("a simulator must never be moved to the Trash")
        throw CocoaError(.fileWriteUnknown)
    }
    func deleteSimulator(udid: String) throws {
        lock.lock(); deletedValues.append(udid); lock.unlock()
        let folder = devices.appendingPathComponent(udid)
        switch behavior {
        case .delete: try FileManager.default.removeItem(at: folder)
        case .failWithoutChange: throw CocoaError(.fileWriteUnknown)
        case .succeedWithoutChange: return
        case .deleteThenFail: try FileManager.default.removeItem(at: folder); throw CocoaError(.fileWriteUnknown)
        }
    }
}

final class SpaceCleaningSimulatorsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_000_000)
    private let day: TimeInterval = 86_400

    private func fixture(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SpaceCleaningSimulators-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let canonical = try XCTUnwrap(SpaceCleaningScanner.canonicalURL(root))
        defer { try? FileManager.default.removeItem(at: canonical) }
        try body(canonical)
    }
    private func devices(_ home: URL) -> URL { home.appendingPathComponent("Library/Developer/CoreSimulator/Devices") }
    @discardableResult private func file(_ url: URL, bytes: Int) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: url)
        return url
    }
    /// A device folder with its record and some data, like CoreSimulator writes it.
    @discardableResult private func device(_ home: URL, name: String, udid: String = UUID().uuidString, state: Int = 1,
                                           lastUsed: Date? = nil, lastBooted: Date? = nil, written: Date? = nil,
                                           runtime: String = "com.apple.CoreSimulator.SimRuntime.iOS-27-0", recordUDID: String? = nil) throws -> URL {
        let folder = devices(home).appendingPathComponent(udid)
        try file(folder.appendingPathComponent("data/Containers/Data/app.bin"), bytes: 4_096)
        try file(folder.appendingPathComponent("data/Library/Preferences/prefs.plist"), bytes: 300)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("data/Library/link"), withDestinationURL: URL(fileURLWithPath: "/tmp"))
        var record: [String: Any] = ["UDID": recordUDID ?? udid, "name": name, "runtime": runtime,
                                     "deviceType": "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro", "state": state,
                                     "isDeleted": false, "isEphemeral": false, "runtimePolicy": "System"]
        if let lastUsed { record["lastUsedAt"] = lastUsed }
        if let lastBooted { record["lastBootedAt"] = lastBooted }
        let plist = folder.appendingPathComponent("device.plist")
        try PropertyListSerialization.data(fromPropertyList: record, format: .binary, options: 0).write(to: plist)
        if let written { try FileManager.default.setAttributes([.modificationDate: written], ofItemAtPath: plist.path) }
        return folder
    }
    /// Rewrites a device record the way CoreSimulator does when a device is used.
    private func rewrite(_ folder: URL, state: Int? = nil, lastUsed: Date? = nil) throws {
        let plist = folder.appendingPathComponent("device.plist")
        var record = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any])
        if let state { record["state"] = state }
        if let lastUsed { record["lastUsedAt"] = lastUsed }
        try PropertyListSerialization.data(fromPropertyList: record, format: .binary, options: 0).write(to: plist, options: .atomic)
    }
    private func logicalSize(_ folder: URL) throws -> UInt64 {
        var total: UInt64 = 0
        let items = try XCTUnwrap(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]))
        for case let url as URL in items {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values.isRegularFile == true { total += UInt64(values.fileSize ?? 0) }
        }
        return total
    }
    private func simulatorScope(_ home: URL) throws -> SpaceCleaningScope {
        try XCTUnwrap(SpaceCleaningScanner.recommendedScopes(context: .init(homeDirectory: home)).first { $0.kind == .simulators })
    }
    private func scan(_ home: URL, context: SpaceCleaningContext? = nil, options: SpaceCleaningOptions = .init()) throws -> SpaceCleaningReport {
        SpaceCleaningScanner.scan(scopes: [try simulatorScope(home)], context: context ?? .init(homeDirectory: home), options: options, now: now)
    }

    func testEachDeviceIsOneItemWithItsNameSystemAndLastUse() throws {
        try fixture { home in
            let stale = try device(home, name: "QA Phone", lastUsed: now - 20 * day)
            let recent = try device(home, name: "Agent QA 20261103", lastUsed: now - 2 * day)
            let untouched = try device(home, name: "iPad Air", written: now - 30 * day)
            let fresh = try device(home, name: "New Phone", written: now - day)
            let booted = try device(home, name: "Booted Phone", state: 3, lastUsed: now)
            let older = try device(home, name: "Old Format", lastBooted: now - 40 * day, runtime: "com.apple.CoreSimulator.SimRuntime.xrOS-2-0")
            try file(devices(home).appendingPathComponent("device_set.plist"), bytes: 200)
            try file(devices(home).appendingPathComponent("Junk/file.bin"), bytes: 200)
            try FileManager.default.createDirectory(at: devices(home).appendingPathComponent(UUID().uuidString), withIntermediateDirectories: true)
            try device(home, name: "Mismatch", lastUsed: now - 20 * day, recordUDID: UUID().uuidString)

            let report = try scan(home)
            XCTAssertEqual(report.candidates.count, 6, "only device folders with a matching record are listed")
            XCTAssertEqual(report.issues.filter { $0.kind == .unreadable }.count, 2, "a folder without a valid record is reported, not listed")
            for item in report.candidates {
                XCTAssertEqual(item.url.deletingLastPathComponent().path, devices(home).path, "nothing inside a device is listed")
                XCTAssertNotNil(item.simulator)
                XCTAssertTrue(item.isDirectory)
                XCTAssertFalse(item.isRecommendedForSelection, "a simulator is never preselected")
                XCTAssertNil(item.isBulkVerified)
                XCTAssertEqual(item.kind == .developmentFile || item.kind == .runningApplication, true, "kinds stay ones released builds can read")
            }
            func item(_ url: URL) throws -> SpaceCleaningCandidate { try XCTUnwrap(report.candidates.first { $0.url.path == url.path }) }

            let staleItem = try item(stale)
            XCTAssertEqual(staleItem.title, "模拟器 · QA Phone（iOS 27.0）")
            XCTAssertEqual(staleItem.simulator?.udid, stale.lastPathComponent.uppercased())
            XCTAssertTrue(staleItem.isCleanupSuggestion)
            XCTAssertTrue(staleItem.reason.contains("已 20 天未使用"), staleItem.reason)
            XCTAssertTrue(staleItem.impact.contains("无法恢复"))
            XCTAssertEqual(staleItem.logicalBytes, try logicalSize(stale))
            XCTAssertTrue(staleItem.sizeIsComplete)

            let recentItem = try item(recent)
            XCTAssertTrue(recentItem.canProcess, "a recently used, shut-down simulator can still be chosen by hand")
            XCTAssertFalse(recentItem.isCleanupSuggestion)
            XCTAssertTrue(recentItem.reason.contains("最后使用于 2 天前"), recentItem.reason)

            XCTAssertTrue(try item(untouched).isCleanupSuggestion)
            XCTAssertTrue(try item(untouched).reason.contains("从未启动过"))
            XCTAssertTrue(try item(fresh).canProcess)
            XCTAssertFalse(try item(fresh).isCleanupSuggestion, "a new device may be about to run tests")

            let bootedItem = try item(booted)
            XCTAssertEqual(bootedItem.group, .protected)
            XCTAssertEqual(bootedItem.kind, .runningApplication)

            let olderItem = try item(older)
            XCTAssertEqual(olderItem.title, "模拟器 · Old Format（visionOS 2.0）")
            XCTAssertEqual(olderItem.simulator?.lastUsedAt, now - 40 * day, "older records keep the last boot instead")
            XCTAssertTrue(olderItem.isCleanupSuggestion)
        }
    }

    func testRunningReferencesRunningProgramsAndMissingToolKeepSimulatorsProtected() throws {
        try fixture { home in
            let phone = try device(home, name: "QA Phone", lastUsed: now - 20 * day)
            let udid = phone.lastPathComponent.uppercased()
            func protectedReason(_ context: SpaceCleaningContext) throws -> String? {
                let item = try XCTUnwrap(try scan(home, context: context).candidates.first)
                return item.group == .protected ? item.reason : nil
            }
            XCTAssertNil(try protectedReason(.init(homeDirectory: home)))
            XCTAssertNotNil(try protectedReason(.init(homeDirectory: home, simulatorReferences: [udid])))
            XCTAssertNotNil(try protectedReason(.init(homeDirectory: home, simulatorReferences: ["name=QA Phone"])))
            XCTAssertNotNil(try protectedReason(.init(homeDirectory: home, simulatorReferences: [SpaceCleaningSimulators.unknownReferences])),
                            "an unreadable process table protects every simulator")
            XCTAssertNil(try protectedReason(.init(homeDirectory: home, simulatorReferences: ["name=Other Phone", UUID().uuidString])))
            let program = phone.appendingPathComponent("data/Containers/Bundle/Application/App.app/App").path
            XCTAssertEqual(try protectedReason(.init(homeDirectory: home, runningExecutablePaths: [program])), "模拟器中有程序正在运行，本次保留。")
            let missing = try XCTUnwrap(try scan(home, context: .init(homeDirectory: home, simulatorToolAvailable: false)).candidates.first)
            XCTAssertEqual(missing.group, .protected)
            XCTAssertTrue(missing.reason.contains("simctl"))
        }
    }

    func testReferencesNameDevicesThatBuildsAndToolsTarget() {
        let udid = "abcdef01-2345-6789-abcd-ef0123456789"
        XCTAssertTrue(SpaceCleaningSimulators.references(executable: "/usr/bin/xcodebuild",
            arguments: ["xcodebuild", "test", "-destination", "platform=iOS Simulator,id=\(udid)"]).contains(udid.uppercased()))
        XCTAssertTrue(SpaceCleaningSimulators.references(executable: "/usr/bin/xcodebuild",
            arguments: ["xcodebuild", "-destination", "platform=iOS Simulator,name=iPhone 18 Pro,OS=27.0"]).contains("name=iPhone 18 Pro"))
        XCTAssertTrue(SpaceCleaningSimulators.references(executable: "/usr/bin/xcrun",
            arguments: ["xcrun", "simctl", "boot", "QA Phone"]).contains("name=QA Phone"))
        XCTAssertTrue(SpaceCleaningSimulators.references(executable: "/Applications/Xcode.app/Contents/Developer/usr/bin/simctl",
            arguments: ["/Applications/Xcode.app/Contents/Developer/usr/bin/simctl", "install", udid, "App.app"]).contains(udid.uppercased()))
        XCTAssertTrue(SpaceCleaningSimulators.references(executable: "/usr/bin/swift",
            arguments: ["swift", "build", "-c", "release", "name=QA Phone"]).isEmpty, "only destinations and simctl operands name a device")
        XCTAssertEqual(SpaceCleaningSimulators.uuids(in: "x\(udid)y\(udid.uppercased())"), [udid.uppercased(), udid.uppercased()])

        XCTAssertEqual(SpaceCleaningSimulators.runtimeTitle("com.apple.CoreSimulator.SimRuntime.iOS-27-0"), "iOS 27.0")
        XCTAssertEqual(SpaceCleaningSimulators.runtimeTitle("com.apple.CoreSimulator.SimRuntime.watchOS-11-2"), "watchOS 11.2")
        XCTAssertEqual(SpaceCleaningSimulators.runtimeTitle("com.apple.CoreSimulator.SimRuntime.xrOS-2-0"), "visionOS 2.0")
        XCTAssertEqual(SpaceCleaningSimulators.runtimeTitle("com.example.Custom"), "Custom")
    }

    func testOtherScopesNeverListFilesInsideSimulators() throws {
        try fixture { home in
            let phone = try device(home, name: "QA Phone", lastUsed: now - 20 * day)
            try file(phone.appendingPathComponent("data/Media/large.mov"), bytes: 300_000)
            try file(home.appendingPathComponent("Library/Developer/CoreSimulator/Caches/dyld/cache.bin"), bytes: 300_000)

            // The large-file scan leaves the device set alone.
            let large = SpaceCleaningScanner.scan(scopes: [try simulatorScope(home)], context: .init(homeDirectory: home),
                                                  options: .init(mode: .largeFiles, minimumFileBytes: 1_000), now: now)
            XCTAssertTrue(large.candidates.isEmpty)

            // A wider folder lists each device as one item and keeps CoreSimulator's other data whole.
            let developer = SpaceCleaningScanner.scan(scopes: [.init(directory: home.appendingPathComponent("Library/Developer"))],
                                                      context: .init(homeDirectory: home), now: now)
            XCTAssertEqual(developer.candidates.filter { $0.simulator != nil }.map(\.url.path), [phone.path])
            let others = developer.candidates.filter { $0.simulator == nil }
            XCTAssertFalse(others.isEmpty)
            XCTAssertTrue(others.allSatisfy { $0.group == .protected && !$0.url.path.hasPrefix(phone.path) }, "\(others.map(\.url.path))")

            // A folder inside a device is never split into cleanup items.
            let inside = SpaceCleaningScanner.scan(scopes: [.init(directory: phone.appendingPathComponent("data"))],
                                                   context: .init(homeDirectory: home), now: now)
            XCTAssertTrue(inside.candidates.allSatisfy { !$0.canProcess }, "\(inside.candidates.map(\.url.path))")
        }
    }

    func testSimulatorIsDeletedOnlyThroughXcodeAfterConfirmation() throws {
        try fixture { home in
            let phone = try device(home, name: "QA Phone", lastUsed: now - 20 * day)
            let context = SpaceCleaningContext(homeDirectory: home)
            let candidate = try XCTUnwrap(try scan(home, context: context).candidates.first)
            XCTAssertEqual(SpaceCleaningScanner.revalidate(candidate: candidate, context: context), .unchanged)
            XCTAssertEqual(SpaceCleaningScanner.validatePolicy(candidate: candidate, context: context), .unchanged)
            let mover = SimulatorMover(devices: devices(home))
            var saved: [SpaceCleaningRecord] = []
            func run(confirmed: Bool) -> SpaceCleaningRecord {
                SpaceCleaningTransaction.execute(candidate: candidate, operationID: UUID(), method: .trash, permanentConfirmed: confirmed,
                    mover: mover, validatePolicy: { SpaceCleaningScanner.revalidate(candidate: $0, context: context) == .unchanged ? nil : "已变化" },
                    validateActivity: { item, _ in SpaceCleaningScanner.validatePolicy(candidate: item, context: context) == .unchanged ? nil : "使用中" },
                    persist: { saved.append($0) })
            }
            let unconfirmed = run(confirmed: false)
            XCTAssertEqual(unconfirmed.state, .skipped)
            XCTAssertTrue(mover.deleted.isEmpty)
            XCTAssertTrue(FileManager.default.fileExists(atPath: phone.path))

            let record = run(confirmed: true)
            XCTAssertEqual(record.state, .deleted, record.explanation)
            XCTAssertEqual(record.method, .permanent, "a simulator record is permanent even in a Trash batch")
            XCTAssertEqual(mover.deleted, [phone.lastPathComponent.uppercased()])
            XCTAssertFalse(FileManager.default.fileExists(atPath: phone.path))
            XCTAssertFalse(record.canRestore)
            XCTAssertTrue(saved.contains { $0.state == .deleting }, "the deletion intent is saved before the tool runs")

            // The receipt stays readable: an existing kind, a small proof and optional fields.
            let proof = try XCTUnwrap(record.proof)
            XCTAssertTrue(proof.isValid)
            XCTAssertEqual(proof.entryCount, 1)
            XCTAssertNil(proof.metadataOnly)
            let decoded = try JSONDecoder().decode(SpaceCleaningRecord.self, from: JSONEncoder().encode(record)).validated()
            XCTAssertEqual(decoded, record)
            XCTAssertEqual(decoded.candidate.kind, .developmentFile)
        }
    }

    func testUseOrStateChangeAfterTheScanStopsDeletion() throws {
        try fixture { home in
            let context = SpaceCleaningContext(homeDirectory: home)
            for change in ["booted", "used", "referenced"] {
                let phone = try device(home, name: "QA Phone " + change, lastUsed: now - 20 * day)
                let candidate = try XCTUnwrap(try scan(home, context: context).candidates.first { $0.url.path == phone.path })
                var current = context
                switch change {
                case "booted": try rewrite(phone, state: 3)
                case "used": try rewrite(phone, lastUsed: now)
                default: current.simulatorReferences = [phone.lastPathComponent.uppercased()]
                }
                let mover = SimulatorMover(devices: devices(home))
                let record = SpaceCleaningTransaction.execute(candidate: candidate, operationID: UUID(), method: .permanent, permanentConfirmed: true,
                    mover: mover, validatePolicy: { SpaceCleaningScanner.revalidate(candidate: $0, context: current) == .unchanged ? nil : "已变化" },
                    validateActivity: { item, _ in SpaceCleaningScanner.validatePolicy(candidate: item, context: current) == .unchanged ? nil : "使用中" },
                    persist: { _ in })
                XCTAssertEqual(record.state, .skipped, change)
                XCTAssertTrue(mover.deleted.isEmpty, change)
                XCTAssertTrue(FileManager.default.fileExists(atPath: phone.path), change)
            }
        }
    }

    func testToolFailuresAreReportedWithoutClaimingSuccess() throws {
        try fixture { home in
            let context = SpaceCleaningContext(homeDirectory: home)
            let cases: [(SimulatorMover.Behavior, SpaceCleaningRecordState, Bool)] = [
                (.failWithoutChange, .failed, true), (.succeedWithoutChange, .needsReview, true), (.deleteThenFail, .needsReview, false)
            ]
            for (behavior, expected, remains) in cases {
                let phone = try device(home, name: "QA Phone \(behavior)", lastUsed: now - 20 * day)
                let candidate = try XCTUnwrap(try scan(home, context: context).candidates.first { $0.url.path == phone.path })
                let record = SpaceCleaningTransaction.execute(candidate: candidate, operationID: UUID(), method: .permanent, permanentConfirmed: true,
                    mover: SimulatorMover(devices: devices(home), behavior: behavior), validatePolicy: { _ in nil }, persist: { _ in })
                XCTAssertEqual(record.state, expected, "\(behavior)")
                XCTAssertEqual(FileManager.default.fileExists(atPath: phone.path), remains, "\(behavior)")
                XCTAssertNoThrow(try record.validated())
            }
        }
    }

    func testInterruptedDeletionIsLeftForReviewInXcode() throws {
        try fixture { home in
            let phone = try device(home, name: "QA Phone", lastUsed: now - 20 * day)
            let candidate = try XCTUnwrap(try scan(home).candidates.first)
            var record = SpaceCleaningRecord(operationID: UUID(), candidate: candidate, method: .permanent)
            record.proof = SpaceCleaningSimulators.proof(for: try XCTUnwrap(candidate.simulator), identity: candidate.identity,
                                                         logicalBytes: candidate.logicalBytes)
            record.locationURL = phone; record.state = .deleting
            let reconciled = SpaceCleaningTransaction.reconcile(record)
            XCTAssertEqual(reconciled.state, .needsReview)
            XCTAssertTrue(reconciled.explanation.contains("Xcode"), reconciled.explanation)
            XCTAssertTrue(FileManager.default.fileExists(atPath: phone.path), "an interrupted deletion is never resumed")
        }
    }
}
