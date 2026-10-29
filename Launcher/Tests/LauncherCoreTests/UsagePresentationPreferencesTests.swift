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

    func testBrandPresetsRoundTripAlongsideExistingIcons() throws {
        for brand in UsageBrandIcon.allCases {
            let value = UsageCardIcon.brand(brand)
            try value.validate()
            XCTAssertEqual(try JSONDecoder().decode(UsageCardIcon.self, from: JSONEncoder().encode(value)), value)
        }
        let legacy = Data(#"{"symbol":{"_0":"terminal"}}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(UsageCardIcon.self, from: legacy), .symbol("terminal"))
        XCTAssertThrowsError(try JSONDecoder().decode(UsageCardIcon.self, from: Data(#"{"brand":{"_0":"unregistered-brand"}}"#.utf8)))
    }

    func testStockCategoryMigrationConsolidatesTrafficAndPreservesReferences() throws {
        var previous = UsagePresentationPreferences()
        previous.schemaVersion = 2
        previous.categories = [
            .init(id: "ai-subscription", title: "AI 订阅"), .init(id: "static-isp", title: "静态 ISP"),
            .init(id: "vps-traffic", title: "VPS 流量"), .init(id: "api-balance", title: "API 余额"), .init(id: "uncategorized", title: "未分类")
        ]
        let serviceKey = UsagePresentationSourceID.service(UUID())
        previous.cards[serviceKey] = .init(displayName: "My server", categoryID: "vps-traffic")
        previous.filterCategoryID = "static-isp"
        let restored = try JSONDecoder().decode(UsagePresentationPreferences.self, from: JSONEncoder().encode(previous))
        try restored.validate()
        XCTAssertEqual(Set(restored.categories.map(\.title)), ["订阅", "API", "流量服务", "未分类"])
        XCTAssertEqual(restored.cards[serviceKey]?.categoryID, "traffic-services")
        XCTAssertEqual(restored.cards[serviceKey]?.displayName, "My server")
        XCTAssertEqual(restored.filterCategoryID, "traffic-services")
        XCTAssertEqual(restored.resolvedCategoryID("static-isp"), "traffic-services")
        XCTAssertEqual(restored.resolvedCategoryID("vps-traffic"), "traffic-services")
    }

    func testCategoryMigrationKeepsRenamedDefaultsAndUserCategoryIdentities() throws {
        var previous = UsagePresentationPreferences()
        previous.schemaVersion = 2
        previous.categories = [
            .init(id: "ai-subscription", title: "Research"), .init(id: "static-isp", title: "Office"),
            .init(id: "vps-traffic", title: "VPS 流量"), .init(id: "api-balance", title: "API 余额"),
            .init(id: "custom-balance", title: "API"), .init(id: "uncategorized", title: "未分类")
        ]
        previous.cards["ai.codex"] = .init(categoryID: "ai-subscription")
        previous.filterCategoryID = "static-isp"
        let restored = try JSONDecoder().decode(UsagePresentationPreferences.self, from: JSONEncoder().encode(previous))
        try restored.validate()
        XCTAssertTrue(restored.categories.contains(.init(id: "ai-subscription", title: "Research")))
        XCTAssertTrue(restored.categories.contains(.init(id: "static-isp", title: "Office")))
        XCTAssertTrue(restored.categories.contains(.init(id: "custom-balance", title: "API")))
        XCTAssertTrue(restored.categories.contains(.init(id: "api-balance", title: "API 余额")))
        XCTAssertEqual(restored.cards["ai.codex"]?.categoryID, "ai-subscription")
        XCTAssertEqual(restored.filterCategoryID, "static-isp")
        XCTAssertEqual(restored.resolvedCategoryID("static-isp"), "static-isp")
        XCTAssertEqual(restored.resolvedCategoryID("vps-traffic"), "traffic-services")
    }

    func testLegacyDefaultReferencesMigrateWithoutMaskingInvalidDocuments() throws {
        let key = UsagePresentationSourceID.service(UUID())
        let valid = Data("""
        {"schemaVersion":2,"cards":{"\(key)":{"categoryID":"static-isp"}},"filterCategoryID":"vps-traffic"}
        """.utf8)
        let restored = try JSONDecoder().decode(UsagePresentationPreferences.self, from: valid)
        try restored.validate()
        XCTAssertEqual(restored.cards[key]?.categoryID, "traffic-services")
        XCTAssertEqual(restored.filterCategoryID, "traffic-services")
        let invalid = Data("""
        {"schemaVersion":2,"categories":[{"id":"static-isp","title":"静态 ISP"},{"id":"static-isp","title":"静态 ISP"},{"id":"uncategorized","title":"未分类"}]}
        """.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(UsagePresentationPreferences.self, from: invalid))
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

    func testLegacyStoreLoadsDisplayChoicesWithoutRewritingOrCreatingBackup() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = UsagePresentationStore(url: directory.appendingPathComponent("legacy.json"))
        let original = Data("""
        { "schemaVersion": 1, "aiCollapsed": true, "serviceCollapsed": false,
          "cards": { "ai.codex": { "displayName": "Legacy research", "visible": false } } }
        """.utf8)
        try original.write(to: store.url)
        let restored = try store.load()
        XCTAssertEqual(restored.schemaVersion, 1)
        XCTAssertTrue(restored.isCollapsed(.ai))
        XCTAssertFalse(restored.isCollapsed(.service))
        XCTAssertEqual(restored.cards[UsagePresentationSourceID.ai(.codex)]?.displayName, "Legacy research")
        XCTAssertFalse(try XCTUnwrap(restored.cards[UsagePresentationSourceID.ai(.codex)]).visible)
        XCTAssertNil(restored.cards[UsagePresentationSourceID.ai(.codex)]?.categoryID)
        XCTAssertNil(restored.cards[UsagePresentationSourceID.ai(.codex)]?.addedAt)
        XCTAssertNil(restored.filterCategoryID)
        XCTAssertFalse(restored.categories.isEmpty)
        XCTAssertEqual(try Data(contentsOf: store.url), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.appendingPathExtension("previous").path))
    }

    func testCustomCategoryFilterOrderingAndIndependentAPIIdentitySurviveDiskRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = UsagePresentationStore(url: directory.appendingPathComponent("display.json"))
        let identity = UUID(), otherIdentity = UUID()
        let api = UsagePresentationSourceID.api(identity), service = UsagePresentationSourceID.service(identity)
        let otherAPI = UsagePresentationSourceID.api(otherIdentity)
        XCTAssertNotEqual(api, service)
        XCTAssertNotEqual(api, otherAPI)
        XCTAssertTrue(UsagePresentationSourceID.isValid(api))
        XCTAssertFalse(UsagePresentationSourceID.isValid("api.not-a-uuid"))
        let research = UsageCardCategory(title: "Research APIs")
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        var preferences = UsagePresentationPreferences()
        preferences.categories.append(research)
        preferences.cards[api] = .init(displayName: "Research balance", categoryID: research.id, addedAt: created)
        preferences.cards[service] = .init(displayName: "Service quota", visible: false, addedAt: created.addingTimeInterval(60))
        preferences.cards[otherAPI] = .init(displayName: "Backup balance", categoryID: research.id)
        preferences.sourceOrder = [service, api, otherAPI]
        preferences.sort = .category; preferences.ascending = false; preferences.filterCategoryID = research.id
        try store.save(preferences)
        let restored = try UsagePresentationStore(url: store.url).load()
        XCTAssertEqual(restored, preferences)
        XCTAssertEqual(restored.cards[api]?.categoryID, research.id)
        XCTAssertNil(restored.cards[service]?.categoryID)
        XCTAssertEqual(restored.cards[api]?.addedAt, created)
        XCTAssertEqual(restored.cards[service]?.displayName, "Service quota")
        XCTAssertEqual(restored.sourceOrder, [service, api, otherAPI])
        XCTAssertEqual(restored.filterCategoryID, research.id)
        XCTAssertFalse(restored.ascending)
    }

    func testInvalidCategoryDefinitionsAndReferencesCannotReplaceSavedPreferences() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = UsagePresentationStore(url: directory.appendingPathComponent("display.json"))
        let category = UsageCardCategory(title: "Research")
        let key = UsagePresentationSourceID.ai(.codex)
        var valid = UsagePresentationPreferences()
        valid.categories.append(category); valid.cards[key] = .init(categoryID: category.id)
        try store.save(valid)
        let original = try Data(contentsOf: store.url)
        var invalid: [(String, UsagePresentationPreferences)] = []
        var value = valid; value.categories.append(.init(id: category.id, title: "Different title")); invalid.append(("duplicate category identity", value))
        value = valid; value.categories.append(.init(title: category.title)); invalid.append(("duplicate category name", value))
        value = valid; value.categories.append(.init(title: "")); invalid.append(("empty category name", value))
        value = valid; value.categories.append(.init(title: " Research ")); invalid.append(("untrimmed category name", value))
        value = valid; value.categories = []; invalid.append(("empty category list", value))
        value = valid; value.categories = [category]; invalid.append(("missing uncategorized destination", value))
        value = valid; value.cards[key]?.categoryID = "missing-category"; invalid.append(("missing card category", value))
        value = valid; value.filterCategoryID = "missing-category"; invalid.append(("missing filter category", value))
        value = valid; value.sourceOrder = [key, key]; invalid.append(("duplicate source order", value))
        for (reason, candidate) in invalid {
            XCTAssertThrowsError(try store.save(candidate), reason)
            XCTAssertEqual(try Data(contentsOf: store.url), original, reason)
            XCTAssertEqual(try store.load(), valid, reason)
        }
    }

    func testInvalidStoredCategoryReferenceIsProtectedRatherThanSilentlyRepaired() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = UsagePresentationStore(url: directory.appendingPathComponent("display.json"))
        let valid = UsagePresentationPreferences()
        try store.save(valid)
        var invalid = valid
        invalid.filterCategoryID = "category-no-longer-present"
        let original = try JSONEncoder().encode(invalid)
        try original.write(to: store.url)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save(valid))
        XCTAssertEqual(try Data(contentsOf: store.url), original)
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
