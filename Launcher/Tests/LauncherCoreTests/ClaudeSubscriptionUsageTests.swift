import XCTest
@testable import LauncherCore

final class ClaudeSubscriptionUsageTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func decode(_ body: String) -> ClaudeSubscriptionReading {
        ClaudeSubscriptionUsage.decode(Data(body.utf8), observedAt: now)
    }
    func testOfficialUsageWindowsUsePercentAndISOResetWithoutInventedValues() throws {
        let result = decode(#"{"rate_limits_available":true,"subscription_type":"pro","rate_limits":{"five_hour":{"utilization":12.5,"resets_at":"2027-01-15T12:00:00.000Z"},"seven_day":{"utilization":42,"resets_at":"2027-01-19T12:00:00Z"}},"email":"PRIVATE_SENTINEL","behaviors":{"private":"PRIVATE_SENTINEL"}}"#)
        guard case .ready(let snapshot) = result else { return XCTFail("Expected authentic quota") }
        XCTAssertEqual(snapshot.source, .claudeCLI)
        XCTAssertEqual(snapshot.shortWindow?.usedPercent, 12.5)
        XCTAssertEqual(snapshot.weeklyWindow?.usedPercent, 42)
        XCTAssertEqual(snapshot.shortWindow?.durationMinutes, 300)
        XCTAssertEqual(snapshot.weeklyWindow?.durationMinutes, 10_080)
        XCTAssertEqual(snapshot.observedAt, now)
        XCTAssertEqual(snapshot.accountPlan, .pro)
        XCTAssertNil(snapshot.shortWindow?.resetTimeZoneIdentifier)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self).contains("PRIVATE_SENTINEL"))
    }
    func testAPIKeyAndTemporarilyMissingUsageAreDifferentStates() {
        guard case .loginRequired = decode(#"{"rate_limits_available":false,"subscription_type":null,"rate_limits":null}"#) else { return XCTFail("API identity needs subscription sign-in") }
        guard case .unavailable = decode(#"{"rate_limits_available":true,"subscription_type":"pro","rate_limits":null}"#) else { return XCTFail("Missing server data is not signed-out") }
    }
    func testWeeklyOnlyAndZeroAreValidWithoutManufacturingFiveHours() {
        guard case .ready(let snapshot) = decode(#"{"rate_limits_available":true,"rate_limits":{"five_hour":null,"seven_day":{"utilization":0,"resets_at":null}}}"#) else { return XCTFail("Expected zero-valued weekly observation") }
        XCTAssertNil(snapshot.shortWindow)
        XCTAssertEqual(snapshot.weeklyWindow?.usedPercent, 0)
        XCTAssertEqual(snapshot.comparisonRows.count, 2)
        XCTAssertNil(snapshot.comparisonRows[0])
    }
    func testExpiredAndMissingWindowsDoNotBecomeCurrentZeroReadings() {
        for body in [#"{"five_hour":{"utilization":90,"resets_at":"2020-01-01T00:00:00Z"}}"#, #"{"five_hour":{"utilization":null},"seven_day":null}"#, #"{}"#] {
            guard case .unavailable = decode("{\"rate_limits_available\":true,\"rate_limits\":\(body)}") else { return XCTFail("Expected unavailable") }
        }
        guard case .ready(let snapshot) = decode(#"{"rate_limits_available":true,"rate_limits":{"five_hour":{"utilization":90,"resets_at":"2020-01-01T00:00:00Z"},"seven_day":{"utilization":25}}}"#) else { return XCTFail("Keep independently valid week") }
        XCTAssertNil(snapshot.shortWindow)
        XCTAssertEqual(snapshot.weeklyWindow?.usedPercent, 25)
    }
    func testNewServerRowsAreClassifiedByKindAndNotDisplayLabel() {
        guard case .ready(let snapshot) = decode(#"{"rate_limits_available":true,"subscription_type":"unknown-plan","rate_limits":{"limits":[{"kind":"weekly_scoped","percent":99,"resets_at":null},{"kind":"weekly_all","percent":33,"resets_at":null},{"kind":"session","percent":7,"resets_at":null}]}}"#) else { return XCTFail("Expected known row kinds") }
        XCTAssertEqual(snapshot.shortWindow?.usedPercent, 7)
        XCTAssertEqual(snapshot.weeklyWindow?.usedPercent, 33)
        XCTAssertNil(snapshot.accountPlan)
    }
    func testUnknownRowsCannotDiscardValidLegacyWindows() {
        guard case .ready(let snapshot) = decode(#"{"rate_limits_available":true,"rate_limits":{"five_hour":{"utilization":18},"seven_day":{"utilization":29},"limits":[{"future_metric":{"balance":15}},{"kind":"future_meter","percent":{"new_shape":1}},null,42,{"kind":"weekly_scoped","label":"future format"}]}}"#) else { return XCTFail("Unknown rows must not discard valid legacy windows") }
        XCTAssertEqual(snapshot.shortWindow?.usedPercent, 18)
        XCTAssertEqual(snapshot.weeklyWindow?.usedPercent, 29)
        for row in [#"{"kind":"session","percent":101}"#, #"{"kind":"weekly_all","percent":"33"}"#, #"{"kind":"weekly_all"}"#] {
            guard case .failed = decode("{\"rate_limits_available\":true,\"rate_limits\":{\"limits\":[\(row)]}}") else { return XCTFail("Known rows remain strict") }
        }
    }
    func testMalformedValuesAndWrongTimeRepresentationFailClosed() {
        for meter in [#"{"utilization":true}"#, #"{"utilization":-1}"#, #"{"utilization":101}"#, #"{"utilization":"22"}"#, #"{"utilization":22,"resets_at":1800005000}"#, #"{"utilization":22,"resets_at":"not-a-date"}"#] {
            guard case .failed = decode("{\"rate_limits_available\":true,\"rate_limits\":{\"five_hour\":\(meter)}}") else { return XCTFail("Reject malformed meter: \(meter)") }
        }
        guard case .failed = ClaudeSubscriptionUsage.decode(Data(repeating: 32, count: 262_145), observedAt: now) else { return XCTFail("Bound input") }
        guard case .failed = decode(#"{"rate_limits_available":"true","rate_limits":null}"#) else { return XCTFail("Strict boolean") }
    }
    func testAuthenticationRetainsOnlyKnownCategory() {
        XCTAssertEqual(ClaudeSubscriptionUsage.authentication(Data(#"{"loggedIn":true,"authMethod":"claude.ai","email":"PRIVATE_SENTINEL"}"#.utf8)), .subscription)
        XCTAssertEqual(ClaudeSubscriptionUsage.authentication(Data(#"{"loggedIn":true,"authMethod":"api_key"}"#.utf8)), .apiKey)
        XCTAssertEqual(ClaudeSubscriptionUsage.authentication(Data(#"{"loggedIn":false,"authMethod":"none"}"#.utf8)), .signedOut)
        XCTAssertEqual(ClaudeSubscriptionUsage.authentication(Data(#"{"loggedIn":true,"authMethod":"oauth_token"}"#.utf8)), .other)
        XCTAssertNil(ClaudeSubscriptionUsage.authentication(Data(#"{"loggedIn":"yes","authMethod":"claude.ai"}"#.utf8)))
    }
    func testErrorMessagesNeverEchoPrivateServerText() {
        for error in ["401 PRIVATE_SENTINEL", "429 PRIVATE_SENTINEL", "get_usage not supported PRIVATE_SENTINEL", "network PRIVATE_SENTINEL"] {
            let result = ClaudeSubscriptionUsage.failure(from: Data(error.utf8))
            switch result {
            case .loginRequired(let message), .unavailable(let message), .failed(let message): XCTAssertFalse(message.contains("PRIVATE_SENTINEL"))
            case .ready: XCTFail("Error cannot become a reading")
            }
        }
    }
}
