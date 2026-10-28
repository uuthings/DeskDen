import Foundation
import XCTest
@testable import LauncherCore

final class WorkbenchPreferenceTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("deskden-workbench-preferences-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { if let directory { try FileManager.default.removeItem(at: directory) } }
    private var launcher: ConfigurationStore { ConfigurationStore(url: directory.appendingPathComponent("launcher.json")) }
    private var workbench: WorkbenchPreferenceStore { WorkbenchPreferenceStore(url: directory.appendingPathComponent("workbench.json")) }

    func testMissingOpacityAdoptsSeventyPercentWithoutChangingOtherSettings() throws {
        var original = LauncherConfiguration()
        original.settings.lightAppearance = true
        original.settings.defaultSearchInputMode = .text
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        var settings = try XCTUnwrap(object["settings"] as? [String: Any])
        settings.removeValue(forKey: "glassOpacity"); object["settings"] = settings
        let legacy = try JSONSerialization.data(withJSONObject: object)
        try legacy.write(to: launcher.url)
        let loaded = try XCTUnwrap(ConfigurationStore(url: launcher.url).load())
        XCTAssertEqual(loaded.settings.glassOpacity, 0.70, accuracy: 0.000_001)
        XCTAssertTrue(loaded.settings.lightAppearance)
        XCTAssertEqual(loaded.settings.defaultSearchInputMode, .text)
        XCTAssertEqual(try Data(contentsOf: launcher.url), legacy, "Reading an old configuration must not silently rewrite it.")
    }

    func testGlobalOpacitySurvivesIndependentStoreReloadAndPreservesPreviousVersion() throws {
        let initial = LauncherConfiguration()
        try launcher.save(initial)
        let prior = try Data(contentsOf: launcher.url)
        var changed = initial; changed.settings.glassOpacity = 0.57
        try launcher.save(changed)
        let reloaded = try XCTUnwrap(ConfigurationStore(url: launcher.url).load())
        XCTAssertEqual(reloaded.settings.glassOpacity, 0.57, accuracy: 0.000_001)
        XCTAssertEqual(try Data(contentsOf: launcher.backupURL), prior)
        for boundary in [0.50, 0.90] {
            changed.settings.glassOpacity = boundary; try launcher.save(changed)
            XCTAssertEqual(try XCTUnwrap(launcher.load()).settings.glassOpacity, boundary, accuracy: 0.000_001)
        }
    }

    func testInvalidGlobalOpacityCannotOverwriteCurrentOrBackupFile() throws {
        var original = LauncherConfiguration()
        try launcher.save(original); original.settings.glassOpacity = 0.65; try launcher.save(original)
        let bytes = try Data(contentsOf: launcher.url), backup = try Data(contentsOf: launcher.backupURL)
        for invalid in [Double.nan, Double.infinity, -Double.infinity, -1, 0.0, 0.299, 0.499, 0.901, 1.001] {
            var changed = original; changed.settings.glassOpacity = invalid
            XCTAssertThrowsError(try changed.validate(), "Invalid opacity must fail model validation before encoding.")
            XCTAssertThrowsError(try launcher.save(changed))
            XCTAssertEqual(try Data(contentsOf: launcher.url), bytes)
            XCTAssertEqual(try Data(contentsOf: launcher.backupURL), backup)
        }
    }

    func testOutOfRangeOpacityAlreadyOnDiskIsPreservedForRecovery() throws {
        var value = LauncherConfiguration(); value.settings.glassOpacity = 1.4
        let bytes = try JSONEncoder().encode(value); try bytes.write(to: launcher.url)
        XCTAssertThrowsError(try launcher.load())
        XCTAssertThrowsError(try launcher.save(LauncherConfiguration()))
        XCTAssertEqual(try Data(contentsOf: launcher.url), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: launcher.backupURL.path))
    }

    func testNewAppearanceDefaultsAndAllThemeChoicesSurviveReload() throws {
        let initial = LauncherConfiguration()
        XCTAssertEqual(initial.settings.workbenchTheme, .qingbiMist)
        XCTAssertEqual(initial.settings.workbenchAppearance, .dark)
        XCTAssertEqual(initial.settings.glassOpacity, 0.70)
        XCTAssertTrue(initial.settings.backgroundMotionEnabled)
        for theme in LauncherTheme.allCases {
            var configuration = initial
            configuration.settings.workbenchTheme = theme
            configuration.settings.backgroundMotionEnabled = false
            configuration.settings.reduceMotion = true
            configuration.settings.glassOpacity = 0.83
            try launcher.save(configuration)
            XCTAssertEqual(try launcher.load(), configuration)
        }
    }

    func testLegacyMaterialMigrationPreservesExplicitChoicesAndDoesNotRewriteTheFile() throws {
        for (oldValue, expected) in [(0.30, 0.50), (0.49, 0.50), (0.50, 0.50), (0.60, 0.60), (0.74, 0.74), (0.90, 0.90), (1.0, 0.90)] {
            let legacy = try legacyMaterialData(opacity: oldValue)
            try legacy.write(to: launcher.url)
            let configuration = try XCTUnwrap(launcher.load())
            XCTAssertEqual(configuration.settings.glassOpacity, expected, accuracy: 0.000_001)
            XCTAssertEqual(configuration.settings.workbenchTheme, .arWorld)
            XCTAssertEqual(configuration.settings.defaultSearchInputMode, .text)
            XCTAssertEqual(try Data(contentsOf: launcher.url), legacy)
        }
    }

    func testInvalidLegacyOpacityCannotBeSilentlyClampedOrOverwritten() throws {
        for invalid in [0.299, 1.001, -1.0] {
            let bytes = try legacyMaterialData(opacity: invalid)
            try bytes.write(to: launcher.url)
            XCTAssertThrowsError(try launcher.load())
            XCTAssertThrowsError(try launcher.save(LauncherConfiguration()))
            XCTAssertEqual(try Data(contentsOf: launcher.url), bytes)
        }
    }

    func testLegacyThemeAliasesAndRemovedThemeFallBackToApprovedWorlds() throws {
        for (name, expected) in [("ink", LauncherTheme.arWorld), ("dusk", .thunderCabin), ("mist", .arWorld), ("porcelain", .arWorld)] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: legacyMaterialData(opacity: 0.60)) as? [String: Any])
            var settings = try XCTUnwrap(object["settings"] as? [String: Any])
            settings["workbenchTheme"] = name; object["settings"] = settings
            let value = try launcher.decode(JSONSerialization.data(withJSONObject: object))
            XCTAssertEqual(value.settings.workbenchTheme, expected)
            XCTAssertEqual(value.settings.glassOpacity, 0.60)
        }
    }

    func testFutureMaterialVersionIsPreservedForRecovery() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(LauncherConfiguration())) as? [String: Any])
        var settings = try XCTUnwrap(object["settings"] as? [String: Any])
        settings["interfaceMaterialVersion"] = 3; object["settings"] = settings
        let bytes = try JSONSerialization.data(withJSONObject: object)
        try bytes.write(to: launcher.url)
        XCTAssertThrowsError(try launcher.load())
        XCTAssertThrowsError(try launcher.save(LauncherConfiguration()))
        XCTAssertEqual(try Data(contentsOf: launcher.url), bytes)
    }

    func testAppearanceModesSurviveReloadIndependentlyFromThemeAndMotion() throws {
        for appearance in LauncherAppearance.allCases {
            var value = LauncherConfiguration()
            value.settings.workbenchAppearance = appearance
            value.settings.workbenchTheme = .thunderCabin
            value.settings.backgroundMotionEnabled = false
            try launcher.save(value)
            XCTAssertEqual(try launcher.load(), value)
        }
    }

    func testLegacyLightAppearanceMapsOnlyWhenTheNewFieldIsMissing() throws {
        for light in [false, true] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: legacyMaterialData(opacity: 0.60)) as? [String: Any])
            var settings = try XCTUnwrap(object["settings"] as? [String: Any])
            settings.removeValue(forKey: "workbenchAppearance")
            settings["lightAppearance"] = light; object["settings"] = settings
            let decoded = try launcher.decode(JSONSerialization.data(withJSONObject: object))
            XCTAssertEqual(decoded.settings.workbenchAppearance, light ? .light : .dark)
            settings["workbenchAppearance"] = "system"; object["settings"] = settings
            let explicit = try launcher.decode(JSONSerialization.data(withJSONObject: object))
            XCTAssertEqual(explicit.settings.workbenchAppearance, .system)
        }
    }

    private func legacyMaterialData(opacity: Double) throws -> Data {
        var value = LauncherConfiguration(); value.settings.defaultSearchInputMode = .text
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        var settings = try XCTUnwrap(object["settings"] as? [String: Any])
        settings.removeValue(forKey: "interfaceMaterialVersion")
        settings.removeValue(forKey: "workbenchTheme")
        settings.removeValue(forKey: "workbenchAppearance")
        settings.removeValue(forKey: "backgroundMotionEnabled")
        settings["glassOpacity"] = opacity; object["settings"] = settings
        return try JSONSerialization.data(withJSONObject: object)
    }

    func testNewWorkbenchDoesNotShowDesktopWindowsBeforeUserChooses() throws {
        let defaults = try workbench.load()
        XCTAssertEqual(Set(defaults.cards.map(\.id)), Set(DesktopCardKind.allCases))
        XCTAssertTrue(defaults.cards.allSatisfy { !$0.visible })
        XCTAssertFalse(FileManager.default.fileExists(atPath: workbench.url.path))
    }

    func testAllDesktopCardPreferencesSurvivePersistenceIncludingSecondaryScreenCoordinates() throws {
        var value = WorkbenchPreferences()
        value.sampleInterval = 5; value.menuBarVisible = false
        value.cards[0].visible = true; value.cards[0].floating = true; value.cards[0].small = true
        value.cards[0].locked = true; value.cards[0].clickThrough = true; value.cards[0].source = "claude"
        value.cards[0].x = -1320.5; value.cards[0].y = 640.25
        value.cards[1].visible = true; value.cards[1].x = 130; value.cards[1].y = -640
        value.cards[2].source = "codex"
        try workbench.save(value)
        XCTAssertEqual(try WorkbenchPreferenceStore(url: workbench.url).load(), value)
        let permissions = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: workbench.url.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
    }

    func testInvalidWorkbenchPreferencesNeverOverwriteValidCurrentOrBackup() throws {
        let original = WorkbenchPreferences(); try workbench.save(original)
        var prior = original; prior.sampleInterval = 1; try workbench.save(prior)
        let bytes = try Data(contentsOf: workbench.url)
        let backupURL = workbench.url.appendingPathExtension("previous"), backup = try Data(contentsOf: backupURL)
        var cases: [WorkbenchPreferences] = []
        var invalid = prior; invalid.schemaVersion = 2; cases.append(invalid)
        invalid = prior; invalid.sampleInterval = 0; cases.append(invalid)
        invalid = prior; invalid.sampleInterval = .nan; cases.append(invalid)
        invalid = prior; invalid.cards.removeLast(); cases.append(invalid)
        invalid = prior; invalid.cards[1] = invalid.cards[0]; cases.append(invalid)
        invalid = prior; invalid.cards[0].source = "unknown-account"; cases.append(invalid)
        invalid = prior; invalid.cards[0].x = .infinity; cases.append(invalid)
        invalid = prior; invalid.cards[0].y = .nan; cases.append(invalid)
        for invalid in cases {
            XCTAssertThrowsError(try workbench.save(invalid))
            XCTAssertEqual(try Data(contentsOf: workbench.url), bytes)
            XCTAssertEqual(try Data(contentsOf: backupURL), backup)
        }
    }

    func testCorruptWorkbenchFileCannotBeReplacedByDefaultsOrOverwriteBackup() throws {
        try workbench.save(WorkbenchPreferences())
        var changed = WorkbenchPreferences(); changed.sampleInterval = 1; try workbench.save(changed)
        let backupURL = workbench.url.appendingPathExtension("previous"), backup = try Data(contentsOf: backupURL)
        let corrupt = Data("{\"schemaVersion\": 1, \"cards\": [ interrupted write".utf8)
        try corrupt.write(to: workbench.url)
        XCTAssertThrowsError(try workbench.load())
        XCTAssertThrowsError(try workbench.save(WorkbenchPreferences()))
        XCTAssertEqual(try Data(contentsOf: workbench.url), corrupt)
        XCTAssertEqual(try Data(contentsOf: backupURL), backup)
    }

    func testNewerWorkbenchSchemaAndOversizedFileArePreserved() throws {
        var future = WorkbenchPreferences(); future.schemaVersion = 2
        let encoded = try JSONEncoder().encode(future)
        for bytes in [encoded, Data(repeating: 32, count: 1_048_577)] {
            try bytes.write(to: workbench.url)
            XCTAssertThrowsError(try workbench.load())
            XCTAssertThrowsError(try workbench.save(WorkbenchPreferences()))
            XCTAssertEqual(try Data(contentsOf: workbench.url), bytes)
        }
    }
}
