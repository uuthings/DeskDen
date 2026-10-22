import XCTest
@testable import LauncherCore

final class LauncherPresentationTests:XCTestCase {
    func testLegacyDefaultsKeepKeysAndAllThirtyEightPositions() throws {
        let settings=try JSONDecoder().decode(LauncherSettings.self,from:Data("{}".utf8))
        XCTAssertEqual(settings.defaultView,.keys);XCTAssertFalse(settings.hideUnboundKeys)
        XCTAssertEqual(LauncherPresentationPolicy.visibleKeys(settings:settings,bindings:[:],editing:false),KeyboardLayout.keys)
        XCTAssertEqual(KeyboardLayout.keys.count,38)
    }
    func testPresentationPreferencesRoundTripAndFallBackToEnabledView() throws {
        var settings=LauncherSettings();settings.defaultView = .applications;settings.hideUnboundKeys=true;settings.display = .list
        XCTAssertEqual(try JSONDecoder().decode(LauncherSettings.self,from:JSONEncoder().encode(settings)),settings)
        XCTAssertEqual(LauncherPresentationPolicy.initialView(settings),.applications)
        settings.applicationsEnabled=false
        XCTAssertEqual(LauncherPresentationPolicy.initialView(settings),.keys)
        settings.applicationsEnabled=true;settings.actionsEnabled=false;settings.defaultView = .keys
        XCTAssertEqual(LauncherPresentationPolicy.initialView(settings),.applications)
    }
    func testHiddenKeysStillExistInEditorAndDoNotChangeBindings() {
        var settings=LauncherSettings();settings.hideUnboundKeys=true
        let binding=KeyBinding(target:LaunchTarget(kind:.web,name:"Synthetic",location:"https://example.com"))
        let bindings=["A":binding,"=":binding]
        XCTAssertEqual(LauncherPresentationPolicy.visibleKeys(settings:settings,bindings:bindings,editing:false),["=","A"])
        XCTAssertEqual(LauncherPresentationPolicy.visibleKeys(settings:settings,bindings:bindings,editing:true),KeyboardLayout.keys)
        XCTAssertEqual(bindings.count,2)
    }
    func testUnknownPresentationValueCannotSilentlyRewriteConfiguration() throws {
        var object=try JSONSerialization.jsonObject(with:JSONEncoder().encode(LauncherSettings())) as! [String:Any]
        object["defaultView"]="future-view"
        XCTAssertThrowsError(try JSONDecoder().decode(LauncherSettings.self,from:JSONSerialization.data(withJSONObject:object)))
    }
    func testDuplicateApplicationMovesOnlyAfterConfirmationAndCleansOrphanShortcut() throws {
        let binding=KeyBinding(target:LaunchTarget(kind:.app,name:"Synthetic",location:"/Applications/Synthetic.app"))
        var current=LauncherConfiguration();current.settings.workbenchHotKey=nil;current.bindings["A"]=binding
        current.bindingHotKeys["A"]=BindingHotKey(keyCode:0,control:true,option:true)
        XCTAssertThrowsError(try LauncherBindingMutation.replacing(binding,key:"S",in:current))
        let next=try LauncherBindingMutation.replacing(binding,key:"S",in:current,movingDuplicate:true)
        XCTAssertNil(next.bindings["A"]);XCTAssertEqual(next.bindings["S"],binding);XCTAssertNil(next.bindingHotKeys["A"])
        XCTAssertEqual(current.bindings["A"],binding)
    }
    func testInvalidBindingNeverChangesCandidateAndRemovalKeepsOtherKeys() throws {
        let valid=KeyBinding(target:LaunchTarget(kind:.web,name:"Synthetic",location:"https://example.com/{ID}"))
        var current=LauncherConfiguration();current.bindings=["A":valid,"S":valid]
        let invalid=KeyBinding(target:LaunchTarget(kind:.web,name:"Unsafe",location:"javascript:alert(1)"))
        XCTAssertThrowsError(try LauncherBindingMutation.replacing(invalid,key:"A",in:current))
        XCTAssertEqual(current.bindings["A"],valid)
        let next=try LauncherBindingMutation.replacing(nil,key:"A",in:current)
        XCTAssertNil(next.bindings["A"]);XCTAssertEqual(next.bindings["S"],valid)
    }
}
