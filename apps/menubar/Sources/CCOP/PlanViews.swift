import AppKit
import CCOPKit
import SwiftUI

/// This week against the weekly limit, and each day against the daily share.
/// In the popover and the window's sidebar, above the session totals.
struct PlanView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let s = model.weekStatus {
            VStack(alignment: .leading, spacing: 6) {
                header(s)
                if let used = s.usedFraction {
                    WeekBar(used: used, elapsed: s.elapsedFraction)
                    Text("Week: \(Format.percent(used)) of the limit used, \(Format.percent(s.elapsedFraction)) of the week passed")
                        .font(.caption).foregroundStyle(used > s.elapsedFraction ? .orange : .secondary)
                    DayBars(status: s)
                } else {
                    Text("This week: \(Format.dollars(s.usedMicros)) API-equivalent. Calibrate the weekly limit to see the daily share.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        } else {
            HStack {
                Text("Set your plan and weekly reset to see use against your limit.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Plan…") { model.openPlanSettings?() }.controlSize(.small)
            }
        }
    }

    private func header(_ s: WeekStatus) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(model.plan.tier.title).font(.subheadline.weight(.semibold))
            Text("resets \(s.weekEnd.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())) (in \(Format.duration(s.weekEnd.timeIntervalSince(model.now))))")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button { model.openPlanSettings?() } label: { Image(systemName: "gearshape") }
                .buttonStyle(.borderless)
                .help("Plan settings")
        }
    }
}

/// The used part of the week's limit, with a mark where an even pace would be.
struct WeekBar: View {
    let used: Double
    let elapsed: Double

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15))
                Capsule().fill(used > elapsed ? Color.orange : Color.accentColor)
                    .frame(width: g.size.width * min(1, used))
                Rectangle().fill(Color.primary.opacity(0.7))
                    .frame(width: 2, height: 12)
                    .offset(x: g.size.width * min(1, elapsed) - 1)
                    .help("An even pace would be here")
            }
        }
        .frame(height: 8)
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
                let todayColor = Color(hue: Plan.hue(ofAllowance: share), saturation: 0.85, brightness: 0.85)
                VStack(spacing: 2) {
                    Text(day.isFuture ? "" : Self.percent(share))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(day.isToday ? todayColor : (share > 1 ? Color.red : .secondary))
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.10))
                        RoundedRectangle(cornerRadius: 2)
                            .fill(day.isToday ? todayColor : (share > 1 ? Color.red : Color.secondary.opacity(0.55)))
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

    private static func percent(_ share: Double) -> String {
        share.isFinite ? "\(Int((share * 100).rounded()))%" : "limit"
    }

    private func help(_ day: DayStatus, _ share: Double) -> String {
        let head = "\(day.start.formatted(date: .abbreviated, time: .omitted)): \(Format.dollars(day.costMicros)) API-equivalent"
        guard day.isToday, let allowance = status.todayAllowanceMicros else {
            return head + ", \(Self.percent(share)) of the daily share (1/7 of the weekly limit)"
        }
        return head + ", \(Self.percent(share)) of today's allowance (\(Format.dollars(allowance)): the limit left, spread over the days left)"
    }
}

/// The plan window: tier, weekly reset, and the weekly limit.
struct PlanSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var percent = ""
    @State private var message: String?

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Picker("Plan", selection: Binding(get: { model.plan.tier }, set: { model.plan.setTier($0) })) {
                    ForEach(Tier.allCases) { Text($0.title).tag($0) }
                }
                DatePicker("Weekly limit resets", selection: Binding(
                    get: { model.plan.resetAnchor ?? Self.nextMonday() },
                    set: { model.plan.resetAnchor = $0 }
                ), displayedComponents: [.date, .hourAndMinute])
                Text("Type the reset time that /usage shows in Claude Code. It repeats every 7 days.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Weekly limit") {
                if let s = model.weekStatus {
                    LabeledContent("Used since the last reset", value: "\(Format.dollars(s.usedMicros)) API-equivalent")
                }
                LabeledContent("Weekly limit used now, as /usage shows it") {
                    HStack {
                        TextField("", text: $percent, prompt: Text("37"))
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 70)
                            .onSubmit(calibrate)
                        Text("%")
                        Button("Calibrate", action: calibrate).disabled(model.weekStatus == nil)
                    }
                }
                if let b = model.plan.weeklyBudgetMicros {
                    LabeledContent("Weekly limit", value: "≈ \(Format.dollars(b)) API-equivalent")
                    LabeledContent("Daily share (1/7)", value: "≈ \(Format.dollars(b / 7))")
                    if let a = model.weekStatus?.todayAllowanceMicros {
                        LabeledContent("Today's allowance (limit left ÷ days left)", value: "≈ \(Format.dollars(a))")
                    }
                    if let at = model.plan.calibratedAt {
                        Text("Calibrated \(at.formatted(date: .abbreviated, time: .shortened)) for \(model.plan.tier.title). A new plan scales it by the plans' ratio.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Forget the limit") { model.plan.weeklyBudgetMicros = nil; model.plan.calibratedAt = nil }
                }
                if let message { Text(message).font(.caption).foregroundStyle(.orange) }
                Text("Anthropic does not publish the limits as numbers, and Claude Code does not save the /usage percentages. ccop measures use as API-equivalent cost: the calls priced at API rates, so a cheap cache read weighs less than an output token. Calibrate again when the numbers drift.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        // A grouped Form scrolls and has no height of its own: without this
        // the window shrinks to its title bar.
        .frame(width: 520, height: 560)
        .onAppear { if model.plan.resetAnchor == nil { model.plan.resetAnchor = Self.nextMonday() } }
    }

    private func calibrate() {
        let text = percent.replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)
        guard let p = Double(text), p > 0, p <= 100 else {
            message = "Type a percent above 0 and up to 100, for example 37."
            return
        }
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
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 520),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "ccop Plan"
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
