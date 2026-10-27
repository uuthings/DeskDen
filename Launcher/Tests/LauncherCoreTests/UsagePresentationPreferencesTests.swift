import Foundation
import XCTest
@testable import LauncherCore

final class UsagePresentationPreferencesTests: XCTestCase {
    func testMissingPresentationFieldsRestoreVisibleExpandedDefaults() throws {
        let preferences = try JSONDecoder().decode(UsagePresentationPreferences.self, from: Data("{}".utf8))
        try preferences.validate()
        XCTAssertFalse(preferences.isCollapsed(.ai))
        XCTAssertFalse(preferences.isCollapsed(.service))
        let partial = try JSONDecoder().decode(UsageCardAppearance.self, from: Data("{}".utf8))
        XCTAssertTrue(partial.visible)
        XCTAssertEqual(partial.icon, .automatic)
        XCTAssertNil(partial.displayName)
    }

    func testIndependentProviderIdentityAndDisplayChoicesRoundTrip() throws {
        var preferences = UsagePresentationPreferences()
        let first = UUID(), second = UUID()
        preferences.setCollapsed(true, group: .service)
        preferences.cards[UsagePresentationSourceID.ai(.codex)] = .init(displayName: "Research", icon: .symbol("terminal"), visible: false)
        preferences.cards[UsagePresentationSourceID.service(first)] = .init(icon: .image(UUID().uuidString.lowercased() + ".png"))
        preferences.cards[UsagePresentationSourceID.service(second)] = .init(displayName: "Backup", icon: .symbol("server.rack"))
        try preferences.validate()
        let restored = try JSONDecoder().decode(UsagePresentationPreferences.self, from: JSONEncoder().encode(preferences))
        XCTAssertEqual(restored, preferences)
        XCTAssertFalse(restored.aiCollapsed)
        XCTAssertTrue(restored.serviceCollapsed)
        XCTAssertNotEqual(UsagePresentationSourceID.service(first), UsagePresentationSourceID.service(second))
    }

    func testUnmanagedIconPathsAndInvalidPresentationIdentitiesAreRejected() throws {
        for value in [UsageCardIcon.image("../outside.png"), .image("file:///outside.png"), .image("display.png"), .symbol("unregistered-symbol")] {
            XCTAssertThrowsError(try value.validate())
        }
        var preferences = UsagePresentationPreferences()
        preferences.cards["ai.unsupported"] = .init()
        XCTAssertThrowsError(try preferences.validate())
        preferences.cards = [UsagePresentationSourceID.ai(.codex): .init(displayName: " trailing ")]
        XCTAssertThrowsError(try preferences.validate())
        preferences.cards = [UsagePresentationSourceID.ai(.codex): .init(displayName: "line\nbreak")]
        XCTAssertThrowsError(try preferences.validate())
    }

    func testStorePreservesMalformedOriginalAndValidPreviousSnapshot() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = UsagePresentationStore(url: directory.appendingPathComponent("display.json"))
        var first = UsagePresentationPreferences(); first.aiCollapsed = true
        try store.save(first)
        let original = try Data(contentsOf: store.url)
        var second = first; second.serviceCollapsed = true
        try store.save(second)
        XCTAssertEqual(try store.load(), second)
        XCTAssertEqual(try Data(contentsOf: store.url.appendingPathExtension("previous")), original)
        let damaged = Data("{invalid".utf8)
        try damaged.write(to: store.url)
        XCTAssertThrowsError(try store.save(first))
        XCTAssertEqual(try Data(contentsOf: store.url), damaged)
    }

    func testStoreDoesNotFollowPrimaryOrBackupSymlinks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("original.json")
        let originalData = try JSONEncoder().encode(UsagePresentationPreferences())
        try originalData.write(to: original)
        let store = UsagePresentationStore(url: directory.appendingPathComponent("display.json"))
        try FileManager.default.createSymbolicLink(at: store.url, withDestinationURL: original)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save(.init()))
        XCTAssertEqual(try Data(contentsOf: original), originalData)
        try FileManager.default.removeItem(at: store.url)
        try store.save(.init())
        try FileManager.default.createSymbolicLink(at: store.url.appendingPathExtension("previous"), withDestinationURL: original)
        XCTAssertThrowsError(try store.save(.init()))
        XCTAssertEqual(try Data(contentsOf: original), originalData)
    }

    func testManagementLinksUseFixedOriginsAndValidatedOrderIdentity() {
        let source = ProviderUsageConfiguration(kind: .iproyal, name: "Fixture", resourceID: "12345")
        let url = ProviderUsageExternalLinks.url(for: source)
        XCTAssertEqual(url?.absoluteString, "https://dashboard.iproyal.com/me/orders/12345?tab=data-usage")
        XCTAssertNil(url?.user)
        XCTAssertNil(url?.password)
        for identifier in ["", "0", "01", "1/other", "1?token=value", String(repeating: "1", count: 21)] {
            var altered = source; altered.resourceID = identifier
            XCTAssertNil(ProviderUsageExternalLinks.url(for: altered))
        }
        let vps = ProviderUsageConfiguration(kind: .bandwagon, name: "Fixture", resourceID: "12345")
        XCTAssertEqual(ProviderUsageExternalLinks.url(for: vps)?.absoluteString, "https://bandwagonhost.com/services")
    }
}
