import Foundation
import XCTest
@testable import LauncherCore

final class UsageResetTimeTests: XCTestCase {
    private let shanghai = TimeZone(identifier: "Asia/Shanghai")!
    private let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
    private let utc = TimeZone(secondsFromGMT: 0)!

    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    func testRollingDayBoundaryDoesNotRequireSameCalendarDate() {
        let now = date("2026-11-01T00:01:00Z")
        let reset = UsageResetTime(resetsAt: date("2026-11-02T00:00:00Z"))
        XCTAssertEqual(reset.state(at: now, timeZone: shanghai), .relative)
        XCTAssertEqual(reset.summary(at: now, timeZone: shanghai), "23小时59分钟后重置")
        XCTAssertEqual(reset.summary(at: now.addingTimeInterval(-60), timeZone: shanghai), "24小时后重置")
        XCTAssertEqual(reset.state(at: now.addingTimeInterval(-61), timeZone: shanghai), .absolute)
        XCTAssertEqual(reset.summary(at: now.addingTimeInterval(-61), timeZone: shanghai), "11月2日 08:00 重置")
    }

    func testCrossMidnightCountdownIncludesMinutes() {
        let now = date("2026-11-01T04:30:00Z")
        let reset = UsageResetTime(resetsAt: date("2026-11-01T16:20:00Z"))
        XCTAssertEqual(reset.summary(at: now, timeZone: shanghai), "11小时50分钟后重置")
        XCTAssertEqual(reset.details(at: now, timeZone: shanghai).workbenchValue, "2026年11月2日 00:20")
    }

    func testChangingDisplayTimezonePreservesRemainingTime() {
        let now = date("2026-11-02T06:10:00Z")
        let reset = UsageResetTime(resetsAt: date("2026-11-03T06:00:00Z"), sourceTimeZoneIdentifier: "America/Los_Angeles")
        for zone in [shanghai, losAngeles, TimeZone(identifier: "Europe/London")!] {
            XCTAssertEqual(reset.summary(at: now, timeZone: zone), "23小时50分钟后重置")
        }
        let china = reset.details(at: now, timeZone: shanghai)
        let california = reset.details(at: now, timeZone: losAngeles)
        XCTAssertEqual(china.workbenchValue, "2026年11月3日 14:00")
        XCTAssertEqual(california.workbenchValue, "2026年11月2日 22:00")
        XCTAssertEqual(china.sourceValue, california.sourceValue)
        XCTAssertEqual(china.sourceZone, "America/Los_Angeles · UTC−08:00")
        XCTAssertEqual(china.workbenchZone, "Asia/Shanghai · UTC+08:00")
    }

    func testSummerTimeUsesResetInstantOffsetAndElapsedHours() {
        // LA jumps from 01:59 to 03:00. Four wall-clock hours span three real hours.
        let now = date("2026-03-08T08:00:00Z")
        let reset = UsageResetTime(resetsAt: date("2026-03-08T11:00:00Z"), sourceTimeZoneIdentifier: "America/Los_Angeles")
        XCTAssertEqual(reset.summary(at: now, timeZone: losAngeles), "3小时后重置")
        XCTAssertEqual(reset.details(at: now, timeZone: losAngeles).sourceValue, "2026年3月8日 04:00")
        XCTAssertEqual(reset.details(at: now, timeZone: losAngeles).sourceZone, "America/Los_Angeles · UTC−07:00")
    }

    func testSameDayRuleCoversTwentyFiveHourAutumnDay() {
        // LA repeats 01:00. Both instants are on Nov 1 locally, 24h20m apart.
        let now = date("2026-11-01T07:10:00Z")
        let reset = UsageResetTime(resetsAt: date("2026-11-02T07:30:00Z"), sourceTimeZoneIdentifier: "America/Los_Angeles")
        XCTAssertEqual(reset.state(at: now, timeZone: losAngeles), .relative)
        XCTAssertEqual(reset.summary(at: now, timeZone: losAngeles), "24小时20分钟后重置")
        XCTAssertEqual(reset.state(at: now, timeZone: utc), .absolute)
        XCTAssertEqual(reset.details(at: now, timeZone: losAngeles).sourceZone, "America/Los_Angeles · UTC−08:00")
    }

    func testImminentAndElapsedResetNeverInventNextPeriod() {
        let now = date("2026-11-02T06:10:00Z")
        XCTAssertEqual(UsageResetTime(resetsAt: now.addingTimeInterval(60)).summary(at: now, timeZone: shanghai), "1分钟后重置")
        XCTAssertEqual(UsageResetTime(resetsAt: now.addingTimeInterval(59)).summary(at: now, timeZone: shanghai), "即将重置")
        for resetDate in [now, now.addingTimeInterval(-1), now.addingTimeInterval(-86_400)] {
            let reset = UsageResetTime(resetsAt: resetDate)
            XCTAssertEqual(reset.state(at: now, timeZone: shanghai), .waiting)
            XCTAssertEqual(reset.summary(at: now, timeZone: shanghai), "已到重置时间，等待更新")
            XCTAssertEqual(reset.resetsAt, resetDate)
        }
    }

    func testOnlyProviderDateIsNeverConvertedOrCountedDown() {
        let now = date("2026-11-25T06:10:00Z")
        let reset = UsageResetTime(resetsAt: nil, dateText: "2026-11-25")
        for zone in [shanghai, losAngeles] {
            let detail = reset.details(at: now, timeZone: zone)
            XCTAssertEqual(detail.state, .dateOnly)
            XCTAssertEqual(detail.summary, "11月25日重置 · 具体时间未提供")
            XCTAssertEqual(detail.sourceLabel, "服务商日期")
            XCTAssertEqual(detail.sourceValue, "2026-11-25")
            XCTAssertEqual(detail.workbenchValue, "暂无法换算")
        }
        for invalid in ["2026-02-30", "2026-11-0x", "2026-13-01", "2026-11-25T00:00:00Z"] {
            XCTAssertEqual(UsageResetTime(resetsAt: nil, dateText: invalid).summary(at: now, timeZone: shanghai), "未提供重置时间")
        }
    }

    func testUnknownSourceTimezoneDoesNotUseTimestampEncodingAsProviderZone() {
        let now = date("2026-11-02T06:10:00Z")
        let reset = UsageResetTime(resetsAt: date("2026-11-03T00:00:00+08:00"))
        let detail = reset.details(at: now, timeZone: shanghai)
        XCTAssertEqual(detail.sourceValue, "来源时区未提供")
        XCTAssertNil(detail.sourceZone)
        XCTAssertFalse(detail.explanation.contains("两个时区"))
        XCTAssertEqual(detail.workbenchValue, "2026年11月3日 00:00")
        XCTAssertNil(UsageResetTime.sourceTimeZone(identifier: "UTC+08:00"))
        XCTAssertNil(UsageResetTime.sourceTimeZone(identifier: "invalid/timezone"))
        XCTAssertNotNil(UsageResetTime.sourceTimeZone(identifier: "UTC"))
    }

    func testDateOnlyWithKnownSourceTimezoneRetainsItsCalendarWithoutInventingAnInstant() {
        let now = date("2026-11-01T06:10:00Z")
        let reset = UsageResetTime(resetsAt: nil, dateText: "2026-11-01", sourceTimeZoneIdentifier: "America/Los_Angeles")
        for zone in [shanghai, losAngeles] {
            let detail = reset.details(at: now, timeZone: zone)
            XCTAssertEqual(detail.state, .dateOnly)
            XCTAssertEqual(detail.sourceValue, "2026-11-01")
            XCTAssertEqual(detail.sourceZone, "America/Los_Angeles · 具体时间未提供")
            XCTAssertEqual(detail.workbenchValue, "暂无法换算")
            // This date includes a DST transition. With no time of day, neither
            // a UTC offset nor a workbench date can be chosen truthfully.
            XCTAssertFalse(reset.help(at: now, timeZone: zone).contains("UTC−"))
            XCTAssertNil(reset.resetsAt)
        }
        let missingInstant = UsageResetTime(resetsAt: nil, sourceTimeZoneIdentifier: "America/Los_Angeles")
        XCTAssertEqual(missingInstant.details(at: now, timeZone: shanghai).sourceZone, "America/Los_Angeles")
    }

    func testUnavailableAndInvalidInstantDoNotBecomeZeroCountdown() {
        let now = date("2026-11-02T06:10:00Z")
        for reset in [UsageResetTime(resetsAt: nil), UsageResetTime(resetsAt: Date(timeIntervalSince1970: .infinity))] {
            XCTAssertEqual(reset.state(at: now, timeZone: shanghai), .unavailable)
            XCTAssertEqual(reset.summary(at: now, timeZone: shanghai), "未提供重置时间")
            XCTAssertEqual(reset.details(at: now, timeZone: shanghai).workbenchValue, "未提供重置时间")
        }
    }

    func testOptionalSourceTimezonePreservesOldAIArchivesAndValidatesImports() throws {
        let old = Data(#"{"usedPercent":42,"durationMinutes":300,"resetsAt":1800000000}"#.utf8)
        let decoded = try JSONDecoder().decode(AIQuotaWindow.self, from: old)
        XCTAssertNil(decoded.resetTimeZoneIdentifier)
        let now = date("2026-11-02T06:10:00Z")
        let window = try AIQuotaWindow(usedPercent: 42, durationMinutes: 300, resetsAt: now.addingTimeInterval(3600),
                                       resetTimeZoneIdentifier: "America/Los_Angeles")
        let snapshot = AIQuotaSnapshot(provider: .codex, observedAt: now, source: .imported, shortWindow: window, weeklyWindow: nil)
        let restored = try AIQuotaImport.decode(AIQuotaImport.encode(snapshot), now: now)
        XCTAssertEqual(restored.shortWindow?.resetTimeZoneIdentifier, "America/Los_Angeles")
        XCTAssertEqual(UsageResetTime(window: window).sourceTimeZoneIdentifier, "America/Los_Angeles")
        XCTAssertThrowsError(try AIQuotaWindow(usedPercent: 42, durationMinutes: 300, resetsAt: now, resetTimeZoneIdentifier: "UTC+08:00"))
    }

    func testOptionalSourceTimezonePreservesProviderArchivesAndValidatesMetadata() throws {
        let now = date("2026-11-02T06:10:00Z")
        var snapshot = ProviderUsageSnapshot(sourceID: UUID(), observedAt: now, usedBytes: 40, limitBytes: 100,
                                            resetsAt: now.addingTimeInterval(3600), displayUnit: .decimalGB, sourceDescription: "fixture")
        let oldData = try JSONEncoder().encode(snapshot)
        XCTAssertFalse(String(decoding: oldData, as: UTF8.self).contains("resetTimeZoneIdentifier"))
        XCTAssertNil(try JSONDecoder().decode(ProviderUsageSnapshot.self, from: oldData).resetTimeZoneIdentifier)
        snapshot.resetTimeZoneIdentifier = "America/Los_Angeles"
        try snapshot.validate(now: now)
        XCTAssertEqual(try JSONDecoder().decode(ProviderUsageSnapshot.self, from: JSONEncoder().encode(snapshot)), snapshot)
        XCTAssertEqual(UsageResetTime(snapshot: snapshot).sourceTimeZoneIdentifier, "America/Los_Angeles")
        snapshot.resetTimeZoneIdentifier = "invalid/timezone"
        XCTAssertThrowsError(try snapshot.validate(now: now))
    }
}
