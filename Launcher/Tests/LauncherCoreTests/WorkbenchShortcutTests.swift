import Foundation
import XCTest
@testable import LauncherCore

final class WorkbenchShortcutTests: XCTestCase {
    private let custom = BindingHotKey(keyCode: 13, control: true, option: true, shift: true)

    func testNewConfigurationHasIndependentWorkbenchShortcut() throws {
        let configuration = LauncherConfiguration()
        XCTAssertEqual(configuration.settings.workbenchHotKey, BindingHotKey(keyCode: 13, control: true, option: true))
        XCTAssertNotEqual(configuration.settings.workbenchHotKey, configuration.settings.hotKey.bindingHotKey)
        XCTAssertNoThrow(try configuration.validate())
    }

    func testMissingLegacyFieldStaysUnsetAndDoesNotRewriteConfiguration() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(LauncherConfiguration())) as? [String: Any])
        var settings = try XCTUnwrap(object["settings"] as? [String: Any])
        settings.removeValue(forKey: "workbenchHotKey")
        object["settings"] = settings
        let bytes = try JSONSerialization.data(withJSONObject: object)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fangcun-workbench-shortcut-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = ConfigurationStore(url: directory.appendingPathComponent("configuration.json"))
        try bytes.write(to: store.url)
        let restored = try XCTUnwrap(store.load())
        XCTAssertNil(restored.settings.workbenchHotKey)
        XCTAssertEqual(try Data(contentsOf: store.url), bytes)
    }

    func testSavedCombinationAndExplicitClearRoundTrip() throws {
        var original = LauncherConfiguration()
        original.settings.workbenchHotKey = custom
        let saved = try JSONDecoder().decode(LauncherConfiguration.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(saved.settings.workbenchHotKey, custom)
        XCTAssertEqual(saved.settings.hotKey, original.settings.hotKey)
        original.settings.workbenchHotKey = nil
        let cleared = try JSONDecoder().decode(LauncherConfiguration.self, from: JSONEncoder().encode(original))
        XCTAssertNil(cleared.settings.workbenchHotKey)
    }

    func testWorkbenchCannotDuplicateLauncherOrApplicationsShortcut() throws {
        var configuration = LauncherConfiguration()
        configuration.settings.workbenchHotKey = configuration.settings.hotKey.bindingHotKey
        XCTAssertThrowsError(try configuration.validate())
        configuration.settings.workbenchHotKey = custom
        configuration.settings.applicationViewHotKey = custom
        XCTAssertThrowsError(try configuration.validate())
        configuration.settings.applicationsEnabled = false
        XCTAssertThrowsError(try configuration.validate(), "A disabled panel still reserves its saved shortcut for future re-enabling.")
    }

    func testWorkbenchCannotDuplicateExplicitOrInheritedBinding() throws {
        let target = LaunchTarget(kind: .web, name: "示例", location: "https://example.com")
        var configuration = LauncherConfiguration()
        configuration.bindings["A"] = KeyBinding(target: target)
        configuration.settings.workbenchHotKey = custom
        configuration.bindingHotKeys["A"] = custom
        XCTAssertThrowsError(try configuration.validate())
        configuration.bindingHotKeys = [:]
        configuration.settings.directLaunchPrefix = KeyShortcutPrefix(control: true, option: true)
        configuration.settings.workbenchHotKey = configuration.settings.directLaunchPrefix?.shortcut(for: "A")
        XCTAssertThrowsError(try configuration.validate())
        configuration.settings.workbenchHotKey = custom
        XCTAssertNoThrow(try configuration.validate())
    }

    func testInvalidWorkbenchCombinationCannotReplaceSavedBytes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fangcun-workbench-shortcut-validation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigurationStore(url: directory.appendingPathComponent("configuration.json"))
        var configuration = LauncherConfiguration()
        try store.save(configuration)
        let bytes = try Data(contentsOf: store.url)
        for invalid in [BindingHotKey(keyCode: 13), BindingHotKey(keyCode: 13, shift: true), BindingHotKey(keyCode: 57, control: true)] {
            configuration.settings.workbenchHotKey = invalid
            XCTAssertThrowsError(try store.save(configuration))
            XCTAssertEqual(try Data(contentsOf: store.url), bytes)
        }
    }
}
