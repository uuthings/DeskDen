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
    func testMissingLimitsAndTemporarilyMissingUsageAreDifferentStates() {
        guard case .loginRequired(_, .signIn) = decode(#"{"rate_limits_available":false,"subscription_type":null,"rate_limits":null}"#) else { return XCTFail("A login without limits needs a fresh membership sign-in") }
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
        func authentication(_ body: String) -> ClaudeSubscriptionUsage.Authentication? { ClaudeSubscriptionUsage.authentication(Data(body.utf8)) }
        XCTAssertEqual(authentication(#"{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","apiKeySource":"none","email":"PRIVATE_SENTINEL"}"#), .subscription)
        // The shape Claude Code 2.1.311 reports after a Console login, without identifiers.
        XCTAssertEqual(authentication(#"{"loggedIn":true,"authMethod":"api_key","apiProvider":"firstParty","apiKeySource":"/login managed key","orgName":"PRIVATE_SENTINEL"}"#), .consoleLogin)
        XCTAssertEqual(authentication(#"{"loggedIn":true,"authMethod":"api_key"}"#), .consoleLogin)
        XCTAssertEqual(authentication(#"{"loggedIn":true,"authMethod":"api_key","apiKeySource":"ANTHROPIC_API_KEY"}"#), .configuredKey)
        XCTAssertEqual(authentication(#"{"loggedIn":true,"authMethod":"api_key","apiKeySource":"apiKeyHelper"}"#), .configuredKey)
        XCTAssertEqual(authentication(#"{"loggedIn":true,"authMethod":"api_key_helper"}"#), .configuredKey)
        XCTAssertEqual(authentication(#"{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"bedrock"}"#), .otherProvider)
        XCTAssertEqual(authentication(#"{"loggedIn":false,"authMethod":"none"}"#), .signedOut)
        XCTAssertEqual(authentication(#"{"loggedIn":true,"authMethod":"oauth_token"}"#), .other)
        XCTAssertNil(authentication(#"{"loggedIn":"yes","authMethod":"claude.ai"}"#))
    }
    func testLoginRequirementsNeverOfferToReplaceAnotherLogin() {
        XCTAssertNil(ClaudeSubscriptionUsage.loginRequirement(.subscription))
        guard case .loginRequired(_, .signIn) = ClaudeSubscriptionUsage.loginRequirement(.signedOut) else { return XCTFail("A missing login can be completed") }
        guard case .loginRequired(let message, .switchInTerminal) = ClaudeSubscriptionUsage.loginRequirement(.consoleLogin) else { return XCTFail("A Console login is switched by the person") }
        XCTAssertTrue(message.contains("Console") && message.contains("桌面版") && message.contains("终端"))
        for identity in [ClaudeSubscriptionUsage.Authentication.configuredKey, .otherProvider, .other] {
            guard case .loginRequired(_, .separateLogin) = ClaudeSubscriptionUsage.loginRequirement(identity) else { return XCTFail("\(identity) needs a separate login") }
        }
        XCTAssertEqual(ClaudeSubscriptionUsage.terminalSwitchCommand, "claude auth logout && claude auth login --claudeai")
    }
    func testProcessEnvironmentReadsOnlyTheStoredLogin() {
        let inherited = ["HOME": "/Users/test", "PATH": "/usr/bin", "HTTPS_PROXY": "http://proxy:8080", "CLAUDE_CONFIG_DIR": "/Users/test/.claude-work",
                         "ANTHROPIC_API_KEY": "PRIVATE_SENTINEL", "ANTHROPIC_BASE_URL": "https://gateway.invalid", "ANTHROPIC_PROFILE": "work",
                         "CLAUDE_CODE_OAUTH_TOKEN": "PRIVATE_SENTINEL", "CLAUDE_CODE_USE_BEDROCK": "1", "CLAUDE_CODE_SDK_HAS_HOST_AUTH_REFRESH": "1", "CLAUDECODE": "1"]
        XCTAssertEqual(ClaudeSubscriptionUsage.processEnvironment(inherited, configurationDirectory: nil),
                       ["HOME": "/Users/test", "PATH": "/usr/bin", "HTTPS_PROXY": "http://proxy:8080", "CLAUDE_CONFIG_DIR": "/Users/test/.claude-work"])
        XCTAssertEqual(ClaudeSubscriptionUsage.processEnvironment(inherited, configurationDirectory: "/private/separate")["CLAUDE_CONFIG_DIR"], "/private/separate")
    }
    func testErrorMessagesNeverEchoPrivateServerText() {
        for error in ["401 PRIVATE_SENTINEL", "429 PRIVATE_SENTINEL", "get_usage not supported PRIVATE_SENTINEL", "network PRIVATE_SENTINEL"] {
            let result = ClaudeSubscriptionUsage.failure(from: Data(error.utf8))
            switch result {
            case .loginRequired(let message, _), .unavailable(let message), .failed(let message): XCTAssertFalse(message.contains("PRIVATE_SENTINEL"))
            case .ready: XCTFail("Error cannot become a reading")
            }
        }
    }
}
