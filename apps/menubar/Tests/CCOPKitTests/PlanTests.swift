import Foundation
import XCTest
@testable import CCOPKit

final class PlanTests: XCTestCase {
    var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    func d(_ s: String) -> Date { parseDate(s)! }

    /// $1 an hour (1,000,000 µ$) from `from` for `count` hours.
    func hours(from: String, count: Int, micros: UInt64 = 1_000_000) -> [UsageReport.Hour] {
        (0 ..< count).map { UsageReport.Hour(start: d(from).addingTimeInterval(Double($0) * 3600), costMicros: micros) }
    }

    func testTheWeekStartsAtTheLatestResetBeforeNow() {
        // Reset Thursday 10:00; the anchor can be in the past or the future.
        let anchor = d("2026-10-29T10:00:00Z")
        XCTAssertEqual(Plan.weekStart(anchor: anchor, now: d("2026-11-02T15:00:00Z")), anchor)
        XCTAssertEqual(Plan.weekStart(anchor: anchor, now: d("2026-11-05T10:00:00Z")), d("2026-11-05T10:00:00Z"))
        XCTAssertEqual(Plan.weekStart(anchor: anchor, now: d("2026-11-05T09:59:00Z")), anchor)
        XCTAssertEqual(Plan.weekStart(anchor: d("2026-11-12T10:00:00Z"), now: d("2026-11-02T15:00:00Z")), anchor)
    }

    func testTheWeekDaysTodayAndTheDailyShare() throws {
        let settings = PlanSettings(tier: .max5x, resetAnchor: d("2026-10-29T10:00:00Z"), weeklyBudgetMicros: 70_000_000)
        // Before the reset: not this week. Then 3 hours on Thursday, 20 hours on Monday.
        let report = UsageReport(generatedAt: d("2026-11-02T20:00:00Z"),
                                 hours: hours(from: "2026-10-29T07:00:00Z", count: 3)
                                     + hours(from: "2026-10-29T10:00:00Z", count: 3)
                                     + hours(from: "2026-11-02T00:00:00Z", count: 20))
        let s = try XCTUnwrap(Plan.status(settings: settings, report: report, now: d("2026-11-02T19:30:00Z"), calendar: utc))
        XCTAssertEqual(s.weekStart, d("2026-10-29T10:00:00Z"))
        XCTAssertEqual(s.weekEnd, d("2026-11-05T10:00:00Z"))
        XCTAssertEqual(s.usedMicros, 23_000_000)
        XCTAssertEqual(s.usedFraction!, 23.0 / 70, accuracy: 1e-9)
        // Thu (from 10:00), Fri, Sat, Sun, Mon, Tue, Wed, Thu (to 10:00).
        XCTAssertEqual(s.days.count, 8)
        XCTAssertEqual(s.days.first?.start, d("2026-10-29T10:00:00Z"))
        XCTAssertEqual(s.days.last?.end, d("2026-11-05T10:00:00Z"))
        XCTAssertEqual(s.days.map(\.costMicros), [3_000_000, 0, 0, 0, 20_000_000, 0, 0, 0])
        XCTAssertEqual(s.days.map(\.isToday), [false, false, false, false, true, false, false, false])
        XCTAssertEqual(s.days.map(\.isFuture), [false, false, false, false, false, true, true, true])
        // The daily share is $10.
        XCTAssertEqual(s.dailyShareMicros, 10_000_000)
        // Today's allowance: $67 left before today, for Monday 00:00 to
        // Thursday 10:00 (82 h); Monday is 24 h of them: $67 * 24 / 82.
        XCTAssertEqual(s.todayAllowanceMicros, 19_609_756)
        // Today used $20: 102% of the allowance, over.
        XCTAssertEqual(s.todayOfAllowance!, 20 / (67.0 * 24 / 82), accuracy: 1e-6)
        // Today 102% of its allowance; the week 23 of 70: 33%.
        XCTAssertEqual(Plan.menuLabel(s)?.text, "102%/33%")
        XCTAssertEqual(Plan.menuLabel(s)?.today, "102%")
        XCTAssertEqual(Plan.menuLabel(s)?.week, "33%")
        XCTAssertEqual(Plan.menuLabel(s)?.over, true)
        // A past day is still measured against the daily share (1/7).
        XCTAssertEqual(s.ofAllowance(s.days[0])!, 0.3, accuracy: 1e-9)
        XCTAssertEqual(s.ofAllowance(s.days[4])!, s.todayOfAllowance!, accuracy: 1e-9)
        XCTAssertNil(s.ofAllowance(s.days[5]))
        XCTAssertEqual(s.elapsedFraction, (4 * 24 + 9.5) / (7 * 24), accuracy: 1e-9)
    }

    func testOnTheLastDayTheAllowanceIsAllThatIsLeft() throws {
        // The week is Wednesday 00:00 to Wednesday 00:00; today is the last day, Tuesday.
        let settings = PlanSettings(resetAnchor: d("2026-10-28T00:00:00Z"), weeklyBudgetMicros: 100_000_000)
        // $83 before today (83% of the limit), then $5 today.
        let report = UsageReport(generatedAt: d("2026-11-03T12:00:00Z"),
                                 hours: hours(from: "2026-10-28T00:00:00Z", count: 83)
                                     + hours(from: "2026-11-03T00:00:00Z", count: 5))
        let s = try XCTUnwrap(Plan.status(settings: settings, report: report, now: d("2026-11-03T12:00:00Z"), calendar: utc))
        XCTAssertEqual(s.days.count, 7)
        XCTAssertTrue(s.days[6].isToday)
        // 17% of the week is left, more than the daily share of 14.3%.
        XCTAssertEqual(s.todayAllowanceMicros, 17_000_000)
        XCTAssertEqual(s.todayOfAllowance!, 5.0 / 17, accuracy: 1e-9)
        XCTAssertEqual(Plan.menuLabel(s)?.text, "29%/88%")
        XCTAssertEqual(Plan.menuLabel(s)?.over, false)
    }

    func testTheMenuBarTooltipExplainsBothHalvesOfTheBattery() throws {
        let settings = PlanSettings(resetAnchor: d("2026-10-28T00:00:00Z"), weeklyBudgetMicros: 100_000_000)
        let report = UsageReport(generatedAt: d("2026-11-03T12:00:00Z"),
                                 hours: hours(from: "2026-10-28T00:00:00Z", count: 83)
                                     + hours(from: "2026-11-03T00:00:00Z", count: 5))
        let s = try XCTUnwrap(Plan.status(settings: settings, report: report, now: d("2026-11-03T12:00:00Z"), calendar: utc))
        // 6.5 of 7 days passed: 93%.
        XCTAssertEqual(Plan.menuTooltip(s, resets: "Wed 00:00"), [
            "Today 29% · $5.00 of $17.00",
            "Week 88% · $88.00 of $100.00 · resets Wed 00:00",
        ])
    }

    func testTheTooltipSaysWhenTheWeekIsUsedUp() throws {
        let settings = PlanSettings(resetAnchor: d("2026-10-28T00:00:00Z"), weeklyBudgetMicros: 10_000_000)
        let report = UsageReport(generatedAt: d("2026-11-03T12:00:00Z"),
                                 hours: hours(from: "2026-10-28T00:00:00Z", count: 12)
                                     + hours(from: "2026-11-03T00:00:00Z", count: 1))
        let s = try XCTUnwrap(Plan.status(settings: settings, report: report, now: d("2026-11-03T12:00:00Z"), calendar: utc))
        XCTAssertEqual(Plan.menuTooltip(s, resets: "x").first, "Today: limit used up · $1.00")
    }

    func testWhenTheWeekIsUsedUpTodayHasNoAllowance() throws {
        let settings = PlanSettings(resetAnchor: d("2026-10-28T00:00:00Z"), weeklyBudgetMicros: 10_000_000)
        let report = UsageReport(generatedAt: d("2026-11-03T12:00:00Z"),
                                 hours: hours(from: "2026-10-28T00:00:00Z", count: 12)
                                     + hours(from: "2026-11-03T00:00:00Z", count: 1))
        let s = try XCTUnwrap(Plan.status(settings: settings, report: report, now: d("2026-11-03T12:00:00Z"), calendar: utc))
        XCTAssertEqual(s.todayAllowanceMicros, 0)
        XCTAssertEqual(Plan.menuLabel(s)?.today, "limit")
        XCTAssertEqual(Plan.menuLabel(s)?.text, "limit/\(Int((s.usedFraction! * 100).rounded()))%")
        XCTAssertGreaterThanOrEqual(s.usedFraction!, 1)
        XCTAssertEqual(Plan.menuLabel(s)?.over, true)
    }

    func testTheColorGoesFromGreenToRed() {
        XCTAssertEqual(Plan.hue(ofAllowance: 0), 1.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(Plan.hue(ofAllowance: 0.5), 1.0 / 6, accuracy: 1e-9)
        XCTAssertEqual(Plan.hue(ofAllowance: 1), 0, accuracy: 1e-9)
        XCTAssertEqual(Plan.hue(ofAllowance: 3), 0, accuracy: 1e-9)
        XCTAssertEqual(Plan.hue(ofAllowance: .infinity), 0, accuracy: 1e-9)
        XCTAssertEqual(Plan.hue(ofAllowance: -1), 1.0 / 3, accuracy: 1e-9)
    }

    func testWithoutALimitThereIsNoShare() throws {
        let settings = PlanSettings(resetAnchor: d("2026-10-29T10:00:00Z"))
        let report = UsageReport(generatedAt: d("2026-11-02T20:00:00Z"), hours: hours(from: "2026-11-02T00:00:00Z", count: 2))
        let s = try XCTUnwrap(Plan.status(settings: settings, report: report, now: d("2026-11-02T19:30:00Z"), calendar: utc))
        XCTAssertEqual(s.todayMicros, 2_000_000)
        XCTAssertNil(s.usedFraction)
        XCTAssertNil(Plan.menuLabel(s))
        XCTAssertNil(Plan.status(settings: PlanSettings(), report: report, now: d("2026-11-02T19:30:00Z")))
    }

    func testCalibrationAndTierChanges() {
        // /usage says 25% while ccop measured $40 since the reset: the limit is $160.
        XCTAssertEqual(Plan.calibrate(usedPercent: 25, usedMicros: 40_000_000), 160_000_000)
        XCTAssertNil(Plan.calibrate(usedPercent: 0, usedMicros: 40_000_000))
        var s = PlanSettings(tier: .max5x, weeklyBudgetMicros: 160_000_000)
        s.setTier(.max20x)
        XCTAssertEqual(s.weeklyBudgetMicros, 640_000_000)
        s.setTier(.pro)
        XCTAssertEqual(s.weeklyBudgetMicros, 32_000_000)
        var none = PlanSettings(tier: .pro)
        none.setTier(.max20x)
        XCTAssertNil(none.weeklyBudgetMicros)
        XCTAssertEqual(none.tier, .max20x)
    }

    func testSettingsAreSaved() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ccop-tests-\(UUID().uuidString)"))
        XCTAssertEqual(PlanSettings.load(defaults), PlanSettings())
        let s = PlanSettings(tier: .max20x, resetAnchor: d("2026-10-29T10:00:00Z"), weeklyBudgetMicros: 5, calibratedAt: d("2026-11-02T10:00:00Z"))
        s.save(defaults)
        XCTAssertEqual(PlanSettings.load(defaults), s)
    }

    func testAnHourCountsInTheRangeItOverlaps() {
        let report = UsageReport(generatedAt: d("2026-11-02T20:00:00Z"), hours: hours(from: "2026-11-02T10:00:00Z", count: 2))
        XCTAssertEqual(report.cost(from: d("2026-11-02T10:30:00Z"), to: d("2026-11-03T00:00:00Z")), 2_000_000)
        XCTAssertEqual(report.cost(from: d("2026-11-02T11:00:00Z"), to: d("2026-11-03T00:00:00Z")), 1_000_000)
        XCTAssertEqual(report.cost(from: d("2026-11-02T12:00:00Z"), to: d("2026-11-03T00:00:00Z")), 0)
    }

    func testTheUsageJSONDecodes() throws {
        let json = #"{"generated_at":"2026-11-02T20:00:00.123456Z","hours":[{"start":"2026-11-02T10:00:00Z","usage":{"input_tokens":2,"cache_write_tokens":10,"cache_write_1h_tokens":0,"cache_read_tokens":1000,"output_tokens":10,"requests":1},"cost_micros":458}]}"#
        let r = try UsageReport.decode(Data(json.utf8))
        XCTAssertEqual(r.hours.first?.costMicros, 458)
        XCTAssertEqual(r.hours.first?.usage.cacheReadTokens, 1000)
        XCTAssertEqual(Format.dollars(458), "$0.00")
        XCTAssertEqual(Format.dollars(12_300_000), "$12.30")
        XCTAssertEqual(Format.dollars(1_234_500_000), "$1,235")
    }
}
