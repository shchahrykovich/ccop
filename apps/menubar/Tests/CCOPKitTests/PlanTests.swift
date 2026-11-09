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

    func testEachDayStartHasAPlaceOnTheWeekBar() throws {
        let settings = PlanSettings(resetAnchor: d("2026-10-29T10:00:00Z"), weeklyBudgetMicros: 70_000_000)
        let report = UsageReport(generatedAt: d("2026-11-02T20:00:00Z"), hours: [])
        let s = try XCTUnwrap(Plan.status(settings: settings, report: report, now: d("2026-11-02T19:30:00Z"), calendar: utc))
        // Thursday from 10:00 is 14 of the week's 168 hours; then 24 hours a day.
        XCTAssertEqual(s.position(of: s.days[0].start), 0)
        XCTAssertEqual(s.position(of: s.days[1].start), 14.0 / 168, accuracy: 1e-9)
        XCTAssertEqual(s.position(of: s.days[2].start), 38.0 / 168, accuracy: 1e-9)
        XCTAssertEqual(s.position(of: s.weekEnd), 1)
        XCTAssertEqual(s.position(of: d("2026-10-01T00:00:00Z")), 0)
        // One gap for each day after the first: Fri to the last Thu.
        XCTAssertEqual(s.dayTicks.count, 7)
        XCTAssertEqual(s.dayTicks.first!, 14.0 / 168, accuracy: 1e-9)
        // Today is Monday: from 86 to 110 of the week's 168 hours.
        let today = try XCTUnwrap(s.todayOnBar)
        XCTAssertEqual(today.lowerBound, 86.0 / 168, accuracy: 1e-9)
        XCTAssertEqual(today.upperBound, 110.0 / 168, accuracy: 1e-9)
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

    func testTheBatteryLightsBlocksByTheUsedPart() {
        // Nothing used: no block is lit.
        XCTAssertEqual(Plan.batteryBlocks(used: 0, rows: 5), 0)
        // Any use lights one block.
        XCTAssertEqual(Plan.batteryBlocks(used: 0.01, rows: 5), 1)
        // Half: 3 of 5 blocks.
        XCTAssertEqual(Plan.batteryBlocks(used: 0.5, rows: 5), 3)
        // Full or over: 5 blocks.
        XCTAssertEqual(Plan.batteryBlocks(used: 1.4, rows: 5), 5)
        // A broken number counts as full.
        XCTAssertEqual(Plan.batteryBlocks(used: .nan, rows: 5), 5)
    }

    func testTheWeekToneComparesTheUsedPartWithTheTimePassed() {
        // The screenshot case: 74% used, 79% of the week passed. Green, like the
        // Week card, even with 4 of 5 blocks lit.
        XCTAssertEqual(Plan.weekTone(used: 0.74, elapsed: 0.79), .ok)
        XCTAssertEqual(Plan.weekTone(used: 0.5, elapsed: 0.5), .ok)
        // Ahead of the time: orange.
        XCTAssertEqual(Plan.weekTone(used: 0.5, elapsed: 0.3), .warn)
        // 90% or more: red, even late in the week.
        XCTAssertEqual(Plan.weekTone(used: 0.9, elapsed: 0.99), .bad)
        XCTAssertEqual(Plan.weekTone(used: 1.3, elapsed: 0.5), .bad)
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

    func testThisWeekIsComparedWithTheWeekBefore() throws {
        let settings = PlanSettings(tier: .max5x, resetAnchor: d("2026-10-29T10:00:00Z"), weeklyBudgetMicros: 70_000_000)
        // Last week: $2 on its first day, $3 on its last day. This week: $4 so far.
        let report = UsageReport(generatedAt: d("2026-11-02T20:00:00Z"),
                                 hours: hours(from: "2026-10-22T10:00:00Z", count: 2)
                                     + hours(from: "2026-10-29T07:00:00Z", count: 3)
                                     + hours(from: "2026-10-29T10:00:00Z", count: 1)
                                     + hours(from: "2026-11-02T10:00:00Z", count: 3))
        let now = d("2026-11-02T13:30:00Z")
        let status = try XCTUnwrap(Plan.status(settings: settings, report: report, now: now, calendar: utc))
        let c = Plan.comparison(status, report: report, now: now)
        // Both start at 0, at the reset.
        XCTAssertEqual(c.current.first, WeekComparison.Point(hour: 0, micros: 0))
        XCTAssertEqual(c.previous.first, WeekComparison.Point(hour: 0, micros: 0))
        // The running total of this week is what the week card shows.
        XCTAssertEqual(c.currentTotal, status.usedMicros)
        XCTAssertEqual(c.currentTotal, 4_000_000)
        XCTAssertEqual(c.previousTotal, 5_000_000)
        XCTAssertEqual(c.peak, 5_000_000)
        XCTAssertEqual(c.budgetMicros, 70_000_000)
        // The last week's line has all 7 days; this week's stops at now, 99.5 h in.
        XCTAssertEqual(c.previous.last?.hour, 168)
        XCTAssertEqual(c.current.last?.hour, 99.5)
        // At this point of the last week only its first $2 were used.
        XCTAssertEqual(c.previousByNow, 2_000_000)
        // A running total never goes down.
        XCTAssertEqual(c.previous.map(\.micros), c.previous.map(\.micros).sorted())
    }

    func testAComparisonRightAfterAResetHasAPointAtNow() throws {
        let settings = PlanSettings(tier: .max5x, resetAnchor: d("2026-10-29T10:00:00Z"), weeklyBudgetMicros: 70_000_000)
        let report = UsageReport(generatedAt: d("2026-10-29T10:10:00Z"), hours: hours(from: "2026-10-29T10:00:00Z", count: 1))
        let now = d("2026-10-29T10:10:00Z")
        let status = try XCTUnwrap(Plan.status(settings: settings, report: report, now: now, calendar: utc))
        let c = Plan.comparison(status, report: report, now: now)
        XCTAssertEqual(c.current.count, 2)
        XCTAssertEqual(c.current.last?.hour ?? 0, 1.0 / 6, accuracy: 1e-9)
        XCTAssertEqual(c.currentTotal, 1_000_000)
        XCTAssertEqual(c.previousTotal, 0)
        XCTAssertEqual(c.previousByNow, 0)
    }

    func testTheSoFarGraphStopsTheLastWeekAtNow() throws {
        let settings = PlanSettings(tier: .max5x, resetAnchor: d("2026-10-29T10:00:00Z"), weeklyBudgetMicros: 70_000_000)
        // Last week: $2 in its first hours, $3 at its end. This week: $1.
        let report = UsageReport(generatedAt: d("2026-10-29T13:30:00Z"),
                                 hours: hours(from: "2026-10-22T10:00:00Z", count: 2)
                                     + hours(from: "2026-10-29T07:00:00Z", count: 3)
                                     + hours(from: "2026-10-29T12:00:00Z", count: 1))
        let now = d("2026-10-29T13:30:00Z")
        let status = try XCTUnwrap(Plan.status(settings: settings, report: report, now: now, calendar: utc))
        let whole = Plan.comparison(status, report: report, now: now)
        let soFar = whole.soFar
        // This week does not change; the last week ends where this week is.
        XCTAssertEqual(soFar.current, whole.current)
        XCTAssertEqual(soFar.previous.last, WeekComparison.Point(hour: 3.5, micros: 2_000_000))
        XCTAssertEqual(soFar.previousTotal, whole.previousByNow)
        // The peak is only what the shorter graph shows, not the $5 of the whole last week.
        XCTAssertEqual(whole.peak, 5_000_000)
        XCTAssertEqual(soFar.peak, 2_000_000)
    }

    func testAnAxisTopIsARoundNumberAtOrAboveTheValue() {
        XCTAssertEqual(Plan.axisTop(1.14), 1.2, accuracy: 1e-9)
        XCTAssertEqual(Plan.axisTop(0.07), 0.08, accuracy: 1e-9)
        XCTAssertEqual(Plan.axisTop(0.005), 0.005, accuracy: 1e-9)
        XCTAssertEqual(Plan.axisTop(1), 1, accuracy: 1e-9)
        XCTAssertEqual(Plan.axisTop(95), 100, accuracy: 1e-9)
        // Nothing used yet.
        XCTAssertEqual(Plan.axisTop(0), 1)
    }

    func testAxisTicksAreMidnightsForLongRangesAndRoundHoursForShortOnes() {
        let start = d("2026-11-03T20:00:00Z")
        let week = Plan.axisTicks(from: start, hours: 168, calendar: utc)
        XCTAssertTrue(week.byDay)
        // 4 h to the first midnight, then one a day; none at the end of the week.
        XCTAssertEqual(week.hours, [4, 28, 52, 76, 100, 124, 148])

        let short = Plan.axisTicks(from: start, hours: 5.5, calendar: utc)
        XCTAssertFalse(short.byDay)
        XCTAssertEqual(short.hours, [1, 2, 3, 4, 5])

        // 22:00, 00:00, 02:00, 04:00; from a start that is not on the hour.
        // 06:00 is at 9.5 of 10 hours: too close to the end.
        let half = d("2026-11-03T20:30:00Z")
        XCTAssertEqual(Plan.axisTicks(from: half, hours: 10, calendar: utc).hours, [1.5, 3.5, 5.5, 7.5])

        // A day: 6 hours apart, on the clock's 0, 6, 12 and 18.
        XCTAssertEqual(Plan.axisTicks(from: start, hours: 24, calendar: utc).hours, [4, 10, 16, 22])
    }

    func testNoAxisTickIsSoCloseToTheEndThatItsLabelIsCutOff() {
        // 6 h 1 min from 20:00: the tick at 2:00 is 1 minute from the right edge.
        let start = d("2026-11-03T20:00:00Z")
        XCTAssertEqual(Plan.axisTicks(from: start, hours: 6 + 1.0 / 60, calendar: utc).hours, [2, 4])
    }

    func testACostIsShownAsAPartOfTheDayAndWeekLimits() {
        // The limit is $70 a week, so a day is $10.
        XCTAssertEqual(Plan.limitShare(costMicros: 2_800_000, weeklyBudgetMicros: 70_000_000), "28% of day · 4.0% of week limit")
        // More than a day's limit: the percent goes over 100.
        XCTAssertEqual(Plan.limitShare(costMicros: 25_000_000, weeklyBudgetMicros: 70_000_000), "250% of day · 36% of week limit")
        // A small cost does not show as 0%: $0.41 of $2,100 a week.
        XCTAssertEqual(Plan.limitShare(costMicros: 410_000, weeklyBudgetMicros: 2_100_000_000), "0.14% of day · 0.02% of week limit")
        // More than the week's limit.
        XCTAssertEqual(Plan.limitShare(costMicros: 140_000_000, weeklyBudgetMicros: 70_000_000), "1400% of day · 200% of week limit")
        XCTAssertEqual(Plan.limitShare(costMicros: 0, weeklyBudgetMicros: 70_000_000), "0% of day · 0% of week limit")
    }

    func testACostHasNoLimitShareWithoutALimit() {
        XCTAssertNil(Plan.limitShare(costMicros: 2_800_000, weeklyBudgetMicros: nil))
        XCTAssertNil(Plan.limitShare(costMicros: 2_800_000, weeklyBudgetMicros: 0))
        XCTAssertNil(Plan.limitParts(costMicros: 2_800_000, weeklyBudgetMicros: nil))
        XCTAssertNil(Plan.limitParts(costMicros: 2_800_000, weeklyBudgetMicros: 0))
    }

    func testTheLimitPartsAreTheDayAndTheWeek() throws {
        // $11.27 of $2,100 a week, so $300 a day.
        let parts = try XCTUnwrap(Plan.limitParts(costMicros: 11_270_000, weeklyBudgetMicros: 2_100_000_000))
        XCTAssertEqual(parts.day, "3.8%")
        XCTAssertEqual(parts.week, "0.54%")
    }

    func testASmallPercentKeepsDecimalsOnlyWhenItIsSmall() {
        XCTAssertEqual(Format.smallPercent(0), "0%")
        XCTAssertEqual(Format.smallPercent(0.00001), "<0.01%")
        XCTAssertEqual(Format.smallPercent(0.0005), "0.05%")
        XCTAssertEqual(Format.smallPercent(0.037), "3.7%")
        XCTAssertEqual(Format.smallPercent(0.26), "26%")
        XCTAssertEqual(Format.smallPercent(14), "1400%")
        // At the edges the rounded number decides, so there is no "1.00%" or "10.0%".
        XCTAssertEqual(Format.smallPercent(0.00999), "1.0%")
        XCTAssertEqual(Format.smallPercent(0.0999), "10%")
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
