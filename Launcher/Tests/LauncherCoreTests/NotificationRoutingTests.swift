import XCTest
@testable import LauncherCore

final class NotificationRoutingTests:XCTestCase {
    func testAIProviderIsWhitelistedAndMissingProviderHasExplicitModuleFallback() {
        XCTAssertEqual(DeskDenNotificationTarget.decode(fields:["deskdenRoute":"ai","provider":"codex"]),.ai(.codex))
        XCTAssertEqual(DeskDenNotificationTarget.decode(fields:["deskdenRoute":"ai","provider":"claude"]),.ai(.claude))
        XCTAssertEqual(DeskDenNotificationTarget.decode(fields:["deskdenRoute":"ai","provider":"some-app"]),.ai(nil))
        XCTAssertEqual(DeskDenNotificationTarget.decode(fields:["deskdenRoute":"ai"]),.ai(nil))
    }
    func testDeviceAndNetworkNotificationsCarryOnlyNavigationTargets() {
        XCTAssertEqual(DeskDenNotificationTarget.decode(fields:["deskdenRoute":"network","detail":"budget"]),.networkBudget)
        XCTAssertEqual(DeskDenNotificationTarget.decode(fields:["deskdenRoute":"device","detail":"thermal"]),.thermal)
        XCTAssertEqual(DeskDenNotificationTarget.decode(fields:["deskdenRoute":"device"]),.device)
        XCTAssertNil(DeskDenNotificationTarget.decode(fields:["deskdenRoute":"network","detail":"disconnect"]))
        XCTAssertNil(DeskDenNotificationTarget.decode(fields:["deskdenRoute":"shell","command":"rm"]))
        XCTAssertNil(DeskDenNotificationTarget.decode(fields:["deskdenRoute":"https://example.com"]))
    }
    func testReminderIdentifierIsBoundedAndNeverInterpretedAsAnAction() {
        XCTAssertEqual(DeskDenNotificationTarget.decode(fields:["deskdenRoute":"calendar","reminderID":"local-1"]),.reminder("local-1"))
        XCTAssertEqual(DeskDenNotificationTarget.decode(fields:["deskdenRoute":"calendar"]),.reminder(nil))
        XCTAssertEqual(DeskDenNotificationTarget.decode(fields:["deskdenRoute":"calendar","reminderID":""]),.reminder(nil))
        XCTAssertEqual(DeskDenNotificationTarget.decode(fields:["deskdenRoute":"calendar","reminderID":"one\ntwo"]),.reminder(nil))
        XCTAssertEqual(DeskDenNotificationTarget.decode(fields:["deskdenRoute":"calendar","reminderID":String(repeating:"x",count:1025)]),.reminder(nil))
    }
    func testExistingDeliveredNotificationsStillNavigateWithoutNewMetadata() {
        XCTAssertEqual(DeskDenNotificationTarget.decode(fields:["reminderID":"old-1"]),.reminder("old-1"))
        XCTAssertEqual(DeskDenNotificationTarget.decode(fields:[:],requestIdentifier:ReminderNotificationPlan.prefix+"old-2"),.reminder("old-2"))
        XCTAssertEqual(DeskDenNotificationTarget.decode(fields:[:],requestIdentifier:"deskden-device-old"),.device)
        XCTAssertNil(DeskDenNotificationTarget.decode(fields:[:],requestIdentifier:"other-notification"))
        XCTAssertNil(DeskDenNotificationTarget.decode(fields:["deskdenRoute":"unknown","reminderID":"valid"],requestIdentifier:ReminderNotificationPlan.prefix+"valid"))
    }
    func testOversizedRequestIdentifierIsRejected() {
        XCTAssertNil(DeskDenNotificationTarget.decode(fields:["deskdenRoute":"ai","provider":"codex"],requestIdentifier:String(repeating:"x",count:2049)))
    }
    func testStartupPresentationDoesNotConfuseBackgroundAndLauncher() {
        XCTAssertEqual(DeskDenStartupPresentation(arguments:[]),.workbench)
        XCTAssertEqual(DeskDenStartupPresentation(arguments:["app","--launcher"]),.launcher)
        XCTAssertEqual(DeskDenStartupPresentation(arguments:["app","--material-preview"]),.launcher)
        XCTAssertEqual(DeskDenStartupPresentation(arguments:["app","--background"]),.background)
        XCTAssertEqual(DeskDenStartupPresentation(arguments:["app","--launcher","--background"]),.background)
    }
}
