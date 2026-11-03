import AppKit
import CCOPKit
import SwiftUI

/// Today and this week against the limits, as two cards. In the popover and
/// the window's sidebar; a click opens the plan settings.
struct PlanCards: View {
    @Environment(AppModel.self) private var model
    var compact = false

    var body: some View {
        if let s = model.weekStatus {
            Button { model.openPlanSettings?() } label: {
                HStack(spacing: compact ? 8 : 10) {
                    todayCard(s)
                    weekCard(s)
                }
            }
            .buttonStyle(.plain)
            .help("Plan settings")
        } else {
            HStack(spacing: 8) {
                if model.limitsReading {
                    ProgressView().controlSize(.small)
                    Text("Reading your limits from Claude Code…").font(.caption).foregroundStyle(.secondary)
                } else {
                    Image(systemName: "gauge.with.dots.needle.33percent").foregroundStyle(.secondary)
                    Text(model.limitsError == nil ? "Read your limits from Claude Code to see today and the week."
                        : "Could not read your limits from Claude Code.")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button("Plan…") { model.openPlanSettings?() }.controlSize(.small)
            }
        }
    }

    private func todayCard(_ s: WeekStatus) -> some View {
        let part = s.todayOfAllowance
        let color = part.map(Theme.allowance) ?? .secondary
        let caption: String = if let a = s.todayAllowanceMicros {
            "\(Format.dollars(s.todayMicros)) of \(Format.dollars(a)) for today"
        } else {
            "\(Format.dollars(s.todayMicros)) today"
        }
        return card(title: "Today", value: part.map(Self.percent) ?? Format.dollars(s.todayMicros), color: color,
                    fill: part ?? 0, mark: nil, caption: caption)
    }

    private func weekCard(_ s: WeekStatus) -> some View {
        let used = s.usedFraction
        let color: Color = switch used {
        case let u? where u >= 0.9: Theme.bad
        case let u? where u > s.elapsedFraction: Theme.warn
        case .some: Theme.ok
        case nil: .secondary
        }
        let reset = s.weekEnd.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        return card(title: "Week", value: used.map(Self.percent) ?? Format.dollars(s.usedMicros), color: color,
                    fill: used ?? 0, mark: s.elapsedFraction,
                    caption: "\(Format.percent(s.elapsedFraction)) of week passed · resets \(reset)")
    }

    private func card(title: String, value: String, color: Color, fill: Double, mark: Double?, caption: String) -> some View {
        VStack(alignment: .leading, spacing: compact ? 5 : 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title.uppercased()).font(.system(size: compact ? 10 : 11, weight: .semibold)).tracking(0.4)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(value).font(.system(size: compact ? 13 : 17, weight: .semibold)).monospacedDigit().foregroundStyle(color)
            }
            Meter(value: fill, color: color, mark: mark, height: compact ? 4 : 5)
            if !compact {
                Text(caption).font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1).minimumScaleFactor(0.85)
            }
        }
        .padding(.horizontal, compact ? 9 : 11)
        .padding(.vertical, compact ? 7 : 9)
        .frame(maxWidth: .infinity)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.cardStroke))
        .help(caption)
    }

    static func percent(_ f: Double) -> String {
        f.isFinite ? "\(Int((f * 100).rounded()))%" : "limit"
    }
}

/// One column per day of the week. A past day against the daily share (1/7);
/// today against today's allowance (the limit left, spread over the days
/// left), from green to red.
struct DayBars: View {
    let status: WeekStatus

    var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(status.days) { day in
                let share = status.ofAllowance(day) ?? 0
                let todayColor = Theme.allowance(share)
                VStack(spacing: 2) {
                    Text(day.isFuture ? "" : PlanCards.percent(share))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(day.isToday ? todayColor : (share > 1 ? Theme.bad : .secondary))
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 2).fill(Theme.track)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(day.isToday ? todayColor : (share > 1 ? Theme.bad : Color.secondary.opacity(0.55)))
                            .frame(height: 36 * min(2, share) / 2)
                        // The share or the allowance: half the column's height.
                        Rectangle().fill(Color.primary.opacity(0.35)).frame(height: 1).offset(y: -18)
                    }
                    .frame(height: 36)
                    Text(day.start.formatted(.dateTime.weekday(.abbreviated)))
                        .font(.caption2).fontWeight(day.isToday ? .bold : .regular)
                        .foregroundStyle(day.isToday ? .primary : .secondary)
                }
                .frame(maxWidth: .infinity)
                .help(help(day, share))
            }
        }
    }

    private func help(_ day: DayStatus, _ share: Double) -> String {
        let head = "\(day.start.formatted(date: .abbreviated, time: .omitted)): \(Format.dollars(day.costMicros)) API-equivalent"
        guard day.isToday, let allowance = status.todayAllowanceMicros else {
            return head + ", \(PlanCards.percent(share)) of the daily share (1/7 of the weekly limit)"
        }
        return head + ", \(PlanCards.percent(share)) of today's allowance (\(Format.dollars(allowance)): the limit left, spread over the days left)"
    }
}

/// The plan window: the limits read from Claude Code, the week by day,
/// Claude Code's own tips, and a way to type the numbers by hand.
struct PlanSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var percent = ""
    @State private var message: String?
    @State private var manual = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    limitsCard
                    if let s = model.weekStatus, s.budgetMicros != nil {
                        box {
                            SectionLabel("This week by day")
                            DayBars(status: s)
                        }
                    }
                    if let period = model.limits?.periods.last, !period.tips.isEmpty {
                        tipsCard(period)
                    }
                    manualEntry
                    Text("Anthropic does not publish the limits as numbers, and Claude Code does not save them on disk. ccop measures use as API-equivalent cost, so a cheap cache read weighs less than an output token.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
            }
            Divider()
            HStack {
                if model.plan.weeklyBudgetMicros != nil {
                    Button("Forget the limit") { model.plan.weeklyBudgetMicros = nil; model.plan.calibratedAt = nil }
                        .buttonStyle(.borderless).foregroundStyle(Theme.bad)
                }
                Spacer()
                Button("Done") { NSApp.keyWindow?.close() }.keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 540, height: 720)
    }

    private var limitsCard: some View {
        box {
            HStack(spacing: 10) {
                IconTile(symbol: "terminal", color: .primary, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Limits from Claude Code").font(.headline)
                    Text(readLine).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
                if model.limitsReading {
                    ProgressView().controlSize(.small)
                } else {
                    Button { model.readLimits() } label: { Label("Read now", systemImage: "arrow.clockwise") }
                        .buttonStyle(.borderedProminent)
                }
            }
            if let error = model.limitsError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(Theme.warn).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let limits = model.limits {
                VStack(spacing: 10) {
                    ForEach(limits.limits) { l in limitRow(l) }
                }
                .padding(12)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
            }
            if let s = model.weekStatus {
                HStack(spacing: 8) {
                    StatCard(label: "Week cost (ccop)", value: Format.dollars(s.usedMicros))
                    StatCard(label: "Weekly limit", value: s.budgetMicros.map { "≈ " + Format.dollars($0) } ?? "–")
                    StatCard(label: "Daily share", value: s.dailyShareMicros.map(Format.dollars) ?? "–")
                }
                if let week = model.limits?.week, let b = model.plan.weeklyBudgetMicros, model.plan.calibratedAt != nil {
                    Text("\(Format.dollars(UInt64(Double(b) * week.usedPercent / 100))) ÷ \(Int(week.usedPercent))% ≈ \(Format.dollars(b)). The week percent comes from Claude Code; the limit in dollars gives the daily share.")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("ccop reads the limits when it starts, then every hour.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var readLine: String {
        if model.limitsReading { return "Running claude -p /usage…" }
        guard let l = model.limits else { return "From claude -p /usage" }
        let t = { (d: Date) in d.formatted(date: .omitted, time: .shortened) }
        return "From claude -p /usage · read \(t(l.readAt)) · next \(t(l.readAt.addingTimeInterval(AppModel.limitsInterval)))"
    }

    private func limitRow(_ l: UsageLimits.Limit) -> some View {
        let f = l.usedPercent / 100
        let color: Color = f >= 0.9 ? Theme.bad : f >= 0.5 ? Theme.warn : Theme.ok
        return HStack(spacing: 10) {
            Text(l.title).font(.callout.weight(l.scope == nil || l.scope == "all models" ? .medium : .regular))
                .frame(width: 140, alignment: .leading)
            Meter(value: f, color: color, height: 6)
            Text("\(Int(l.usedPercent))%").font(.callout.weight(.semibold)).monospacedDigit().foregroundStyle(color)
                .frame(width: 40, alignment: .trailing)
            Text(l.resetsAt.map { "resets " + $0.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()) }
                ?? l.resetText.map { "resets " + $0 } ?? "")
                .font(.caption).foregroundStyle(.secondary).frame(width: 150, alignment: .leading)
        }
    }

    private func tipsCard(_ period: UsageLimits.Period) -> some View {
        box {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel("Claude Code's tips")
                Text("\(period.title.lowercased()) · \(period.summary)").font(.caption).foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                ForEach(period.tips) { tip in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(tip.percent)%").font(.callout.weight(.semibold)).monospacedDigit().frame(width: 40, alignment: .trailing)
                        Text(tip.text).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 6)
                    .overlay(alignment: .top) { Divider() }
                }
            }
            ForEach(period.extras, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
            Text("Approximate: sessions on this Mac only, and the shares overlap.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var manualEntry: some View {
        DisclosureGroup("Type the numbers yourself", isExpanded: $manual) {
            VStack(alignment: .leading, spacing: 8) {
                DatePicker("Weekly limit resets", selection: Binding(
                    get: { model.plan.resetAnchor ?? Self.nextMonday() },
                    set: { model.plan.resetAnchor = $0 }
                ), displayedComponents: [.date, .hourAndMinute])
                HStack {
                    Text("Week used, as /usage shows it")
                    TextField("", text: $percent, prompt: Text("37"))
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 60)
                        .onSubmit(calibrate)
                    Text("%")
                    Button("Calibrate", action: calibrate).disabled(model.weekStatus == nil)
                }
                if let message { Text(message).font(.caption).foregroundStyle(Theme.warn) }
            }
            .padding(.top, 8)
        }
        .font(.callout)
    }

    private func box<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.cardStroke))
    }

    private func calibrate() {
        let text = percent.replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)
        guard let p = Double(text), p > 0, p <= 100 else {
            message = "Type a percent above 0 and up to 100, for example 37."
            return
        }
        if model.plan.resetAnchor == nil { model.plan.resetAnchor = Self.nextMonday() }
        message = model.calibrate(usedPercent: p) ? nil : "No use measured since the last reset yet: check the reset time, or try again after some work."
    }

    /// A first guess for the reset: next Monday at 00:00.
    static func nextMonday(now: Date = Date(), calendar: Calendar = .current) -> Date {
        let next = calendar.nextDate(after: now, matching: DateComponents(hour: 0, minute: 0, weekday: 2), matchingPolicy: .nextTime)
        return next ?? now
    }
}

@MainActor
final class PlanWindowController {
    private unowned let model: AppModel
    private var window: NSWindow?

    init(model: AppModel) {
        self.model = model
    }

    func show() {
        let w = window ?? {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 720),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Plan settings"
            w.isReleasedWhenClosed = false
            w.contentViewController = NSHostingController(rootView: PlanSettingsView().environment(model))
            w.center()
            return w
        }()
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}
