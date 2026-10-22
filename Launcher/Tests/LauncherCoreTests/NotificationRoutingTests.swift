import XCTest
@testable import LauncherCore

final class NotificationRoutingTests:XCTestCase {
    func testAIProviderIsWhitelistedAndMissingProviderHasExplicitModuleFallback() {
        XCTAssertEqual(FangcunNotificationTarget.decode(fields:["fangcunRoute":"ai","provider":"codex"]),.ai(.codex))
        XCTAssertEqual(FangcunNotificationTarget.decode(fields:["fangcunRoute":"ai","provider":"claude"]),.ai(.claude))
        XCTAssertEqual(FangcunNotificationTarget.decode(fields:["fangcunRoute":"ai","provider":"some-app"]),.ai(nil))
        XCTAssertEqual(FangcunNotificationTarget.decode(fields:["fangcunRoute":"ai"]),.ai(nil))
    }
    func testDeviceAndNetworkNotificationsCarryOnlyNavigationTargets() {
        XCTAssertEqual(FangcunNotificationTarget.decode(fields:["fangcunRoute":"network","detail":"budget"]),.networkBudget)
        XCTAssertEqual(FangcunNotificationTarget.decode(fields:["fangcunRoute":"device","detail":"thermal"]),.thermal)
        XCTAssertEqual(FangcunNotificationTarget.decode(fields:["fangcunRoute":"device"]),.device)
        XCTAssertNil(FangcunNotificationTarget.decode(fields:["fangcunRoute":"network","detail":"disconnect"]))
        XCTAssertNil(FangcunNotificationTarget.decode(fields:["fangcunRoute":"shell","command":"rm"]))
        XCTAssertNil(FangcunNotificationTarget.decode(fields:["fangcunRoute":"https://example.com"]))
    }
    func testReminderIdentifierIsBoundedAndNeverInterpretedAsAnAction() {
        XCTAssertEqual(FangcunNotificationTarget.decode(fields:["fangcunRoute":"calendar","reminderID":"local-1"]),.reminder("local-1"))
        XCTAssertEqual(FangcunNotificationTarget.decode(fields:["fangcunRoute":"calendar"]),.reminder(nil))
        XCTAssertEqual(FangcunNotificationTarget.decode(fields:["fangcunRoute":"calendar","reminderID":""]),.reminder(nil))
        XCTAssertEqual(FangcunNotificationTarget.decode(fields:["fangcunRoute":"calendar","reminderID":"one\ntwo"]),.reminder(nil))
        XCTAssertEqual(FangcunNotificationTarget.decode(fields:["fangcunRoute":"calendar","reminderID":String(repeating:"x",count:1025)]),.reminder(nil))
    }
    func testExistingDeliveredNotificationsStillNavigateWithoutNewMetadata() {
        XCTAssertEqual(FangcunNotificationTarget.decode(fields:["reminderID":"old-1"]),.reminder("old-1"))
        XCTAssertEqual(FangcunNotificationTarget.decode(fields:[:],requestIdentifier:ReminderNotificationPlan.prefix+"old-2"),.reminder("old-2"))
        XCTAssertEqual(FangcunNotificationTarget.decode(fields:[:],requestIdentifier:"fangcun-device-old"),.device)
        XCTAssertNil(FangcunNotificationTarget.decode(fields:[:],requestIdentifier:"other-notification"))
        XCTAssertNil(FangcunNotificationTarget.decode(fields:["fangcunRoute":"unknown","reminderID":"valid"],requestIdentifier:ReminderNotificationPlan.prefix+"valid"))
    }
    func testOversizedRequestIdentifierIsRejected() {
        XCTAssertNil(FangcunNotificationTarget.decode(fields:["fangcunRoute":"ai","provider":"codex"],requestIdentifier:String(repeating:"x",count:2049)))
    }
    func testStartupPresentationDoesNotConfuseBackgroundAndLauncher() {
        XCTAssertEqual(FangcunStartupPresentation(arguments:[]),.workbench)
        XCTAssertEqual(FangcunStartupPresentation(arguments:["app","--launcher"]),.launcher)
        XCTAssertEqual(FangcunStartupPresentation(arguments:["app","--material-preview"]),.launcher)
        XCTAssertEqual(FangcunStartupPresentation(arguments:["app","--background"]),.background)
        XCTAssertEqual(FangcunStartupPresentation(arguments:["app","--launcher","--background"]),.background)
    }
}
