import Foundation
import XCTest
@testable import LauncherCore

final class LauncherShortcutTests:XCTestCase {
    private let custom=BindingHotKey(keyCode:64,control:true,option:true,command:true)
    func testLegacySettingsKeepTheirExistingEffectiveLauncherShortcut() throws {
        for choice in HotKeyChoice.allCases {
            let bytes=Data("{\"hotKey\":\"\(choice.rawValue)\"}".utf8)
            let settings=try JSONDecoder().decode(LauncherSettings.self,from:bytes)
            XCTAssertNil(settings.launcherHotKey)
            XCTAssertEqual(settings.effectiveLauncherHotKey,choice.bindingHotKey)
        }
    }
    func testRecordedLauncherShortcutRoundTripsSeparatelyFromLegacyChoice() throws {
        var configuration=LauncherConfiguration()
        configuration.settings.launcherHotKey=custom
        let restored=try JSONDecoder().decode(LauncherConfiguration.self,from:JSONEncoder().encode(configuration))
        XCTAssertEqual(restored.settings.launcherHotKey,custom)
        XCTAssertEqual(restored.settings.effectiveLauncherHotKey,custom)
        XCTAssertEqual(restored.settings.hotKey,.controlOptionSpace)
        XCTAssertNoThrow(try restored.validate())
    }
    func testCustomLauncherShortcutCannotCollideWithWorkbenchOrApplications() {
        var configuration=LauncherConfiguration();configuration.settings.launcherHotKey=custom
        configuration.settings.workbenchHotKey=custom
        XCTAssertThrowsError(try configuration.validate())
        configuration.settings.workbenchHotKey=nil;configuration.settings.applicationViewHotKey=custom
        XCTAssertThrowsError(try configuration.validate())
        configuration.settings.applicationsEnabled=false
        XCTAssertThrowsError(try configuration.validate())
    }
    func testCustomLauncherShortcutCannotCollideWithExplicitOrInheritedTarget() {
        var configuration=LauncherConfiguration();configuration.settings.launcherHotKey=custom
        configuration.bindings["A"]=KeyBinding(target:LaunchTarget(kind:.web,name:"示例",location:"https://example.com"))
        configuration.bindingHotKeys["A"]=custom
        XCTAssertThrowsError(try configuration.validate())
        configuration.bindingHotKeys=[:];configuration.settings.directLaunchPrefix=KeyShortcutPrefix(control:true,option:true,command:true)
        configuration.settings.launcherHotKey=configuration.settings.directLaunchPrefix?.shortcut(for:"A")
        XCTAssertThrowsError(try configuration.validate())
        configuration.settings.launcherHotKey=custom
        XCTAssertNoThrow(try configuration.validate())
    }
    func testEffectiveCustomShortcutReleasesTheUnusedLegacyCombination() {
        var configuration=LauncherConfiguration();configuration.settings.launcherHotKey=custom
        configuration.settings.workbenchHotKey=configuration.settings.hotKey.bindingHotKey
        XCTAssertNoThrow(try configuration.validate())
        configuration.settings.launcherHotKey=nil
        XCTAssertThrowsError(try configuration.validate())
    }
    func testInvalidRecordedShortcutCannotReplaceSavedConfiguration() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("deskden-launcher-hotkey-\(UUID().uuidString)")
        defer {try? FileManager.default.removeItem(at:directory)}
        let store=ConfigurationStore(url:directory.appendingPathComponent("configuration.json"))
        var configuration=LauncherConfiguration();try store.save(configuration)
        let original=try Data(contentsOf:store.url)
        for invalid in [BindingHotKey(keyCode:13),BindingHotKey(keyCode:13,shift:true),BindingHotKey(keyCode:57,command:true)] {
            configuration.settings.launcherHotKey=invalid
            XCTAssertThrowsError(try store.save(configuration))
            XCTAssertEqual(try Data(contentsOf:store.url),original)
        }
    }
}
