// The subscription plan: the tier, when the weekly limit resets, and the
// weekly limit in API-equivalent dollars. Anthropic does not publish the
// limits as numbers, and Claude Code does not save the /usage percentages,
// so the limit is calibrated: the user types the weekly percent /usage
// shows, and the limit is what ccop measured since the reset divided by it.
//
// Usage is weighted by API price (`ccop usage --json`, libs/core/src/pricing.rs):
// a cache read costs far less than an output token, so raw tokens would
// overstate cache-heavy work.

import Foundation

public enum Tier: String, Codable, CaseIterable, Identifiable, Sendable {
    case pro, max5x, max20x

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .pro: "Pro"
        case .max5x: "Max 5x"
        case .max20x: "Max 20x"
        }
    }

    /// Usage relative to Pro, as the plan names say.
    public var multiplier: Double {
        switch self {
        case .pro: 1
        case .max5x: 5
        case .max20x: 20
        }
    }
}

public struct PlanSettings: Codable, Equatable, Sendable {
    public var tier: Tier
    /// A moment the weekly limit reset or will reset; it repeats every 7 days.
    public var resetAnchor: Date?
    /// The weekly limit for `tier`, in API-equivalent millionths of a dollar.
    public var weeklyBudgetMicros: UInt64?
    public var calibratedAt: Date?

    public init(tier: Tier = .max5x, resetAnchor: Date? = nil, weeklyBudgetMicros: UInt64? = nil, calibratedAt: Date? = nil) {
        self.tier = tier
        self.resetAnchor = resetAnchor
        self.weeklyBudgetMicros = weeklyBudgetMicros
        self.calibratedAt = calibratedAt
    }

    /// A new tier; a calibrated limit scales by the tiers' ratio (Max 5x to
    /// Max 20x: 4 times).
    public mutating func setTier(_ new: Tier) {
        if let b = weeklyBudgetMicros, new != tier {
            weeklyBudgetMicros = UInt64((Double(b) * new.multiplier / tier.multiplier).rounded())
        }
        tier = new
    }

    public static let defaultsKey = "planSettings"

    public static func load(_ defaults: UserDefaults = .standard) -> PlanSettings {
        guard let data = defaults.data(forKey: defaultsKey), let s = try? JSONDecoder().decode(PlanSettings.self, from: data) else {
            return PlanSettings()
        }
        return s
    }

    public func save(_ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}

/// `ccop usage --json`: tokens and API-equivalent cost by hour.
public struct UsageReport: Codable, Equatable, Sendable {
    public struct Hour: Codable, Equatable, Sendable {
        public var start: Date
        public var usage: TokenUsage
        public var costMicros: UInt64

        public init(start: Date, usage: TokenUsage = TokenUsage(), costMicros: UInt64) {
            self.start = start
            self.usage = usage
            self.costMicros = costMicros
        }
    }

    public var generatedAt: Date
    public var hours: [Hour]

    public init(generatedAt: Date, hours: [Hour]) {
        self.generatedAt = generatedAt
        self.hours = hours
    }

    public static func decode(_ data: Data) throws -> UsageReport {
        try Session.makeDecoder().decode(UsageReport.self, from: data)
    }

    /// Cost of the hours that overlap [from, to). An hour is the smallest
    /// unit: a reset at 10:30 still counts the calls of 10:00-10:30.
    public func cost(from: Date, to: Date) -> UInt64 {
        hours.reduce(0) { sum, h in
            h.start.addingTimeInterval(3600) > from && h.start < to ? sum + h.costMicros : sum
        }
    }
}

public struct DayStatus: Equatable, Sendable, Identifiable {
    /// The part of the day inside the week.
    public var start: Date
    public var end: Date
    public var costMicros: UInt64
    public var isToday: Bool
    public var isFuture: Bool
    public var id: Date { start }
}

/// The colour of the week: `Plan.weekTone`.
public enum WeekTone: Equatable, Sendable { case ok, warn, bad }

public struct WeekStatus: Equatable, Sendable {
    public var weekStart: Date
    public var weekEnd: Date
    public var usedMicros: UInt64
    public var budgetMicros: UInt64?
    public var days: [DayStatus]
    public var todayMicros: UInt64
    /// 0...1: how much of the week has passed.
    public var elapsedFraction: Double

    /// The used part of the weekly limit; nil without a limit.
    public var usedFraction: Double? {
        budgetMicros.flatMap { $0 == 0 ? nil : Double(usedMicros) / Double($0) }
    }

    /// The colour of the week; nil without a limit.
    public var tone: WeekTone? {
        usedFraction.map { Plan.weekTone(used: $0, elapsed: elapsedFraction) }
    }

    /// 1/7 of the weekly limit.
    public var dailyShareMicros: UInt64? {
        budgetMicros.map { $0 / 7 }
    }

    /// What today may use: the limit left before today, spread over the rest
    /// of the week by time, so today gets its length's part of it. On the
    /// last full day it is everything that is left; 0 when the week is used up.
    public var todayAllowanceMicros: UInt64? {
        guard let budget = budgetMicros, let today = days.first(where: \.isToday) else { return nil }
        let before = usedMicros - min(usedMicros, todayMicros)
        let left = budget - min(budget, before)
        let rest = weekEnd.timeIntervalSince(today.start)
        guard rest > 0 else { return 0 }
        return UInt64((Double(left) * today.end.timeIntervalSince(today.start) / rest).rounded())
    }

    /// Today's use as a part of today's allowance: 1.0 is exactly the
    /// allowance; infinity when the allowance is 0 and today used something.
    public var todayOfAllowance: Double? {
        todayAllowanceMicros.map { a in
            a == 0 ? (todayMicros == 0 ? 0 : .infinity) : Double(todayMicros) / Double(a)
        }
    }

    /// Today against today's allowance; a past day against the daily share
    /// (1/7); nil for a future day.
    /// Where `date` is on the week bar, 0 at the reset and 1 at the next one.
    public func position(of date: Date) -> Double {
        min(1, max(0, date.timeIntervalSince(weekStart) / weekEnd.timeIntervalSince(weekStart)))
    }

    /// Today's part of the Week card's bar.
    public var todayOnBar: ClosedRange<Double>? {
        days.first(where: \.isToday).map { position(of: $0.start) ... position(of: $0.end) }
    }

    /// The gaps in the Week card's bar: the start of each day after the first.
    public var dayTicks: [Double] {
        days.dropFirst().map { position(of: $0.start) }
    }

    public func ofAllowance(_ day: DayStatus) -> Double? {
        if day.isToday { return todayOfAllowance }
        if day.isFuture { return nil }
        return dailyShareMicros.flatMap { $0 == 0 ? nil : Double(day.costMicros) / Double($0) }
    }
}

/// This week and the week before it, as running totals from each week's
/// reset: is this week ahead of the last one?
public struct WeekComparison: Equatable, Sendable {
    public struct Point: Equatable, Sendable {
        /// Hours since the week's reset.
        public var hour: Double
        /// The cost from the reset to this point.
        public var micros: UInt64

        public init(hour: Double, micros: UInt64) {
            self.hour = hour
            self.micros = micros
        }
    }

    /// From the reset to now.
    public var current: [Point]
    /// The whole week before.
    public var previous: [Point]
    public var budgetMicros: UInt64?

    /// Where the last week was at this point of the week.
    public var previousByNow: UInt64 {
        let now = current.last?.hour ?? 0
        return previous.last { $0.hour <= now }?.micros ?? 0
    }

    public var previousTotal: UInt64 { previous.last?.micros ?? 0 }
    public var currentTotal: UInt64 { current.last?.micros ?? 0 }
    public var peak: UInt64 { max(currentTotal, previousTotal) }

    /// Only the part of the week up to now: the last week's line stops where
    /// this week is, at the value `previousByNow` gives.
    public var soFar: WeekComparison {
        let now = current.last?.hour ?? 0
        var cut = previous.filter { $0.hour <= now }
        if cut.last?.hour != now { cut.append(Point(hour: now, micros: previousByNow)) }
        return WeekComparison(current: current, previous: cut, budgetMicros: budgetMicros)
    }
}

public enum Plan {
    public static let week: TimeInterval = 7 * 24 * 3600

    /// The top of a graph's y axis: the first round number at or above `value`
    /// (1.14 gives 1.2, 0.07 gives 0.08), so the label reads well.
    public static func axisTop(_ value: Double) -> Double {
        guard value > 0, value.isFinite else { return 1 }
        let magnitude = pow(10, floor(log10(value)))
        let factor = [1, 1.2, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10].first { $0 * magnitude >= value * (1 - 1e-9) } ?? 10
        return factor * magnitude
    }

    /// The marks on a graph's time axis, in hours after `start`. Over 36 hours:
    /// each midnight (`byDay`). Shorter: round clock hours, 1, 2 or 6 hours apart.
    /// A label starts at its tick, so none is in the last 8% of the range: its
    /// label would be cut off at the right edge.
    public static func axisTicks(from start: Date, hours: Double,
                                 calendar: Calendar = .current) -> (hours: [Double], byDay: Bool) {
        let end = start.addingTimeInterval(hours * 3600)
        let lastTick = start.addingTimeInterval(hours * 3600 * 0.92)
        var out: [Double] = []
        func add(_ date: Date) {
            if date > start, date <= lastTick { out.append(date.timeIntervalSince(start) / 3600) }
        }
        if hours > 36 {
            var day = calendar.startOfDay(for: start)
            while day < end, let next = calendar.date(byAdding: .day, value: 1, to: day) {
                add(day)
                day = next
            }
            return (out, true)
        }
        let step = hours <= 6 ? 1 : hours <= 12 ? 2 : 6
        var date = calendar.dateInterval(of: .hour, for: start)?.start ?? start
        while date < end {
            if calendar.component(.hour, from: date) % step == 0 { add(date) }
            date = date.addingTimeInterval(3600)
        }
        return (out, false)
    }

    /// This week and the week before from the hours of the report. An hour
    /// that a reset cuts counts in both weeks, as in `UsageReport.cost`.
    public static func comparison(_ status: WeekStatus, report: UsageReport, now: Date) -> WeekComparison {
        func running(from: Date, to: Date) -> [WeekComparison.Point] {
            let span = to.timeIntervalSince(from) / 3600
            var costs = [UInt64](repeating: 0, count: max(1, Int(span.rounded(.up))))
            for h in report.hours where h.start.addingTimeInterval(3600) > from && h.start < to {
                let i = Int((h.start.timeIntervalSince(from) / 3600).rounded(.down))
                costs[min(max(i, 0), costs.count - 1)] += h.costMicros
            }
            var total: UInt64 = 0
            var out = [WeekComparison.Point(hour: 0, micros: 0)]
            for (i, cost) in costs.enumerated() {
                total += cost
                out.append(WeekComparison.Point(hour: min(Double(i + 1), span), micros: total))
            }
            return out
        }
        return WeekComparison(current: running(from: status.weekStart, to: min(now, status.weekEnd)),
                              previous: running(from: status.weekStart.addingTimeInterval(-week), to: status.weekStart),
                              budgetMicros: status.budgetMicros)
    }

    /// The latest reset at or before `now`: the anchor plus or minus whole weeks.
    public static func weekStart(anchor: Date, now: Date) -> Date {
        let weeks = (now.timeIntervalSince(anchor) / week).rounded(.down)
        return anchor.addingTimeInterval(weeks * week)
    }

    public static func status(settings: PlanSettings, report: UsageReport, now: Date,
                              calendar: Calendar = .current) -> WeekStatus? {
        guard let anchor = settings.resetAnchor else { return nil }
        let start = weekStart(anchor: anchor, now: now)
        let end = start.addingTimeInterval(week)
        var days: [DayStatus] = []
        var dayStart = start
        while dayStart < end {
            let next = min(calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: dayStart)) ?? end, end)
            let isFuture = dayStart > now
            let cost = isFuture ? 0 : report.cost(from: dayStart, to: min(next, now.addingTimeInterval(1)))
            days.append(DayStatus(start: dayStart, end: next, costMicros: cost,
                                  isToday: calendar.isDate(dayStart, inSameDayAs: now), isFuture: isFuture))
            dayStart = next
        }
        let today = days.first(where: \.isToday)?.costMicros ?? 0
        return WeekStatus(weekStart: start, weekEnd: end,
                          usedMicros: report.cost(from: start, to: now.addingTimeInterval(1)),
                          budgetMicros: settings.weeklyBudgetMicros, days: days, todayMicros: today,
                          elapsedFraction: min(1, max(0, now.timeIntervalSince(start) / week)))
    }

    /// The weekly limit from the percent /usage shows now and what ccop
    /// measured since the reset. Nil for a percent that is not above 0.
    public static func calibrate(usedPercent: Double, usedMicros: UInt64) -> UInt64? {
        guard usedPercent > 0, usedPercent.isFinite else { return nil }
        return UInt64((Double(usedMicros) / (usedPercent / 100)).rounded())
    }

    /// The menu bar text, `33%/87%`: today as a percent of today's allowance
    /// ("limit" when the week is used up), then the week as a percent of the
    /// weekly limit. `over`: today is over its allowance.
    public static func menuLabel(_ status: WeekStatus) -> (text: String, today: String, week: String?, over: Bool)? {
        guard let fraction = status.todayOfAllowance else { return nil }
        let percent = { (f: Double) in "\(Int((f * 100).rounded()))%" }
        let today = status.todayAllowanceMicros == 0 ? "limit" : percent(fraction)
        let week = status.usedFraction.map(percent)
        return (week.map { "\(today)/\($0)" } ?? today, today, week, status.todayAllowanceMicros == 0 || fraction > 1)
    }

    /// The menu bar battery's tooltip, two short lines: today (the left
    /// half) and the week (the right half). `resets` is the reset moment,
    /// formatted by the caller.
    public static func menuTooltip(_ status: WeekStatus, resets: String) -> [String] {
        let today: String = if let allowance = status.todayAllowanceMicros, allowance > 0, let f = status.todayOfAllowance {
            "Today \(Format.percent(f)) · \(Format.dollars(status.todayMicros)) of \(Format.dollars(allowance))"
        } else if status.todayAllowanceMicros == 0 {
            "Today: limit used up · \(Format.dollars(status.todayMicros))"
        } else {
            "Today \(Format.dollars(status.todayMicros))"
        }
        let week: String = if let used = status.usedFraction, let budget = status.budgetMicros {
            "Week \(Format.percent(used)) · \(Format.dollars(status.usedMicros)) of \(Format.dollars(budget)) · resets \(resets)"
        } else {
            "Week \(Format.dollars(status.usedMicros)) · resets \(resets)"
        }
        return [today, week]
    }

    /// The smallest weekly percent ccop calibrates from: /usage rounds to a
    /// whole percent, so 2% could be anything from 1.5% to 2.5%.
    public static let minCalibrationPercent: Double = 5

    /// Settings after a read of /usage: the weekly reset is the one /usage
    /// shows, and the weekly limit is what ccop measured since that week
    /// started divided by the percent /usage shows. A percent under
    /// `minCalibrationPercent` keeps the old limit. `calibrated`: the limit
    /// was set from this read.
    public static func applying(_ limits: UsageLimits, to settings: PlanSettings,
                                report: UsageReport?) -> (settings: PlanSettings, calibrated: Bool) {
        guard let week = limits.week else { return (settings, false) }
        var s = settings
        if let reset = week.resetsAt { s.resetAnchor = reset }
        guard let report, week.usedPercent >= minCalibrationPercent,
              let status = status(settings: s, report: report, now: limits.readAt), status.usedMicros > 0,
              let budget = calibrate(usedPercent: week.usedPercent, usedMicros: status.usedMicros) else { return (s, false) }
        s.weeklyBudgetMicros = budget
        s.calibratedAt = limits.readAt
        return (s, true)
    }

    /// A cost as a part of the limits: `28% of day · 4% of week limit`. The day
    /// is the daily share (1/7 of the weekly limit), not today's allowance, so
    /// the number of a past session does not change with today's use. Nil
    /// without a limit.
    public static func limitShare(costMicros: UInt64, weeklyBudgetMicros: UInt64?) -> String? {
        limitParts(costMicros: costMicros, weeklyBudgetMicros: weeklyBudgetMicros).map {
            "\($0.day) of day · \($0.week) of week limit"
        }
    }

    /// The two percents of `limitShare`, for a table with a column for each.
    public static func limitParts(costMicros: UInt64, weeklyBudgetMicros: UInt64?) -> (day: String, week: String)? {
        guard let budget = weeklyBudgetMicros, budget > 0 else { return nil }
        let week = Double(costMicros) / Double(budget)
        return (Format.smallPercent(week * 7), Format.smallPercent(week))
    }

    /// The tooltip of `limitShare` and `limitParts`.
    public static let limitShareHelp = "The whole cost against your limits, even if it ran over several days. The week limit is the one from /usage. The day limit is 1/7 of it, so a cost can be over 100% of a day."

    /// The hue for a part of the allowance: green (1/3) at 0, yellow (1/6)
    /// at half, red (0) at the whole allowance and above.
    public static func hue(ofAllowance fraction: Double) -> Double {
        (1 - min(1, max(0, fraction))) / 3
    }

    /// One half of the menu bar battery: how many of `rows` blocks are lit for
    /// the used part (0...1, more is full, any use lights one, a broken number
    /// is full). The colour is not from the count: it is the colour of the
    /// card in the popover (`hue(ofAllowance:)` for today, `weekTone` for the week).
    public static func batteryBlocks(used: Double, rows: Int) -> Int {
        let u = used.isFinite ? max(0, used) : 1
        return u <= 0 ? 0 : max(1, min(rows, Int((u * Double(rows)).rounded())))
    }

    /// How the week stands: the colour of the Week card and of the battery's
    /// right half. Red from 90% of the limit; orange when more of the limit is
    /// used than of the week has passed; green otherwise.
    public static func weekTone(used: Double, elapsed: Double) -> WeekTone {
        if used >= 0.9 { return .bad }
        if used > elapsed { return .warn }
        return .ok
    }
}

public extension Format {
    /// A part of a limit or a total. One subagent is often under 1% of the week, so small
    /// values keep decimals: `<0.01%`, `0.05%`, `3.7%`, `26%`.
    static func smallPercent(_ ratio: Double) -> String {
        let p = ratio * 100
        if p <= 0 { return "0%" }
        if p < 0.01 { return "<0.01%" }
        if (p * 100).rounded() / 100 < 1 { return String(format: "%.2f%%", p) }
        if (p * 10).rounded() / 10 < 10 { return String(format: "%.1f%%", p) }
        return "\(Int(p.rounded()))%"
    }

    /// `$0.42`, `$12.30`, `$1,234`.
    static func dollars(_ micros: UInt64) -> String {
        let d = Double(micros) / 1e6
        if d >= 1000 { return "$" + Int(d.rounded()).formatted(.number.locale(Locale(identifier: "en_US"))) }
        return String(format: "$%.2f", d)
    }
}
