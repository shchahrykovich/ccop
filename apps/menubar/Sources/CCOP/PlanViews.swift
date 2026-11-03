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
        let color = part.map(Theme.allowance) ?? Theme.text2
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
        case nil: Theme.text2
        }
        let reset = s.weekEnd.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        return card(title: "Week", value: used.map(Self.percent) ?? Format.dollars(s.usedMicros), color: color,
                    fill: used ?? 0, mark: s.elapsedFraction,
                    caption: "\(Format.percent(s.elapsedFraction)) of week passed · resets \(reset)")
    }

    private func card(title: String, value: String, color: Color, fill: Double, mark: Double?, caption: String) -> some View {
        VStack(alignment: .leading, spacing: compact ? 5 : 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title.uppercased()).font(.ui(compact ? 10.5 : 11, .semibold)).tracking(0.44)
                    .foregroundStyle(Theme.text2)
                Spacer()
                Text(value).font(.ui(compact ? 13 : 17, .semibold)).monospacedDigit().foregroundStyle(color)
            }
            Meter(value: fill, color: color, mark: mark, height: compact ? 4 : 5)
            if !compact {
                Text(caption).font(.ui(11)).foregroundStyle(Theme.text3).monospacedDigit().lineLimit(1).minimumScaleFactor(0.85)
            }
        }
        .padding(.horizontal, compact ? 9 : 11)
        .padding(.vertical, compact ? 7 : 9)
        .frame(maxWidth: .infinity)
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: compact ? 8 : 9))
        .overlay {
            if !compact { RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.line2) }
        }
        .contentShape(Rectangle())
        .help(caption)
    }

    static func percent(_ f: Double) -> String {
        f.isFinite ? "\(Int((f * 100).rounded()))%" : "limit"
    }
}

/// The plan window (board "Plan settings"): the limits read from Claude
/// Code, Claude Code's own tips, and a way to type the numbers by hand.
struct PlanSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var percent = ""
    @State private var message: String?
    @State private var manual = false

    static let size = NSSize(width: 500, height: 760)

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    limitsCard
                    if let period = model.limits?.periods.last, !period.tips.isEmpty {
                        tipsCard(period)
                    }
                    manualEntry
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 20)
            }
            Rectangle().fill(Theme.line2).frame(height: 1)
            HStack(spacing: 8) {
                Button("Forget the limit") { model.plan.weeklyBudgetMicros = nil; model.plan.calibratedAt = nil }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.bad)
                    .frame(height: 28)
                    .disabled(model.plan.weeklyBudgetMicros == nil)
                Spacer()
                Button("Done") { NSApp.keyWindow?.close() }
                    .buttonStyle(DesignButtonStyle(kind: .bordered, height: 28, padding: 16, weight: .medium))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .background(Theme.bg)
        }
        .font(.ui(13))
        .foregroundStyle(Theme.text)
        .background(Theme.dynamic(0xF5F5F7, 0x262628))
        .frame(width: Self.size.width, height: Self.size.height)
    }

    private var limitsCard: some View {
        box(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "terminal")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Color(nsColor: NSColor(rgb: 0x1D1D1F)), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Limits from Claude Code").font(.ui(13, .semibold))
                    readLine.font(.ui(11.5)).foregroundStyle(Theme.text3).monospacedDigit()
                }
                Spacer()
                if model.limitsReading {
                    ProgressView().controlSize(.small)
                } else {
                    Button { model.readLimits() } label: { IconLabel(title: "Read now", symbol: "arrow.clockwise") }
                        .buttonStyle(DesignButtonStyle(kind: .primary, height: 28, padding: 12))
                }
            }
            if let error = model.limitsError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.ui(11)).foregroundStyle(Theme.warn).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let limits = model.limits, !limits.limits.isEmpty {
                VStack(spacing: 10) {
                    ForEach(Array(limits.limits.enumerated()), id: \.element.id) { i, l in limitRow(l, first: i == 0) }
                }
                .padding(12)
                .background(Theme.soft, in: RoundedRectangle(cornerRadius: 8))
            }
            if let s = model.weekStatus {
                HStack(alignment: .top, spacing: 8) {
                    stat("Week cost (ccop)", Format.dollars(s.usedMicros))
                    stat("Weekly limit", s.budgetMicros.map { "≈ " + Format.dollars($0) } ?? "–")
                    stat("Daily share", s.dailyShareMicros.map(Format.dollars) ?? "–")
                }
                if let week = model.limits?.week, let b = model.plan.weeklyBudgetMicros, model.plan.calibratedAt != nil {
                    Text("The week percent in the menu bar now comes straight from Claude Code. ccop still needs a limit in dollars for the daily share: \(Format.dollars(s.usedMicros)) ÷ \(Int(week.usedPercent))% ≈ \(Format.dollars(b)).")
                        .font(.ui(11)).foregroundStyle(Theme.text3).monospacedDigit().lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Toggle(isOn: Binding(get: { model.autoReadLimits }, set: { model.autoReadLimits = $0 })) {
                Text("Read when ccop starts, then every hour").font(.ui(12))
            }
            .toggleStyle(.checkbox)
        }
    }

    private var readLine: Text {
        let mono = Text("claude -p /usage").font(.mono(11.5))
        if model.limitsReading { return Text("Running ") + mono + Text("…") }
        guard let l = model.limits else { return Text("From ") + mono }
        let t = { (d: Date) in d.formatted(date: .omitted, time: .shortened) }
        let next = model.autoReadLimits ? " · next \(t(l.readAt.addingTimeInterval(AppModel.limitsInterval)))" : ""
        return Text("From ") + mono + Text(" · read \(t(l.readAt))\(next)")
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.ui(11)).foregroundStyle(Theme.text3)
            Text(value).font(.ui(17, .semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static let resetFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM HH:mm"
        return f
    }()

    private func limitRow(_ l: UsageLimits.Limit, first: Bool) -> some View {
        let f = l.usedPercent / 100
        let color: Color = f >= 0.9 ? Theme.bad : f >= 0.5 ? Theme.warn : Theme.ok
        return HStack(spacing: 10) {
            Text(l.title).font(.ui(12, first ? .medium : .regular)).foregroundStyle(first ? Theme.text : Theme.text2)
                .lineLimit(1)
                .frame(width: 150, alignment: .leading)
            Meter(value: max(f, 0.02), color: color, height: 6)
            Text("\(Int(l.usedPercent))%").font(.ui(12, .semibold)).monospacedDigit()
                .foregroundStyle(f >= 0.5 ? color : Theme.text)
                .frame(width: 40, alignment: .trailing)
            Text(l.resetsAt.map { "resets " + Self.resetFormat.string(from: $0) } ?? l.resetText.map { "resets " + $0 } ?? "")
                .font(.ui(12)).foregroundStyle(Theme.text3).lineLimit(1).frame(width: 120, alignment: .leading)
        }
        .monospacedDigit()
    }

    private func tipsCard(_ period: UsageLimits.Period) -> some View {
        box(spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                SectionLabel("Claude Code's tips")
                Text("\(period.title.lowercased()) · \(period.summary) · approximate, shares overlap")
                    .font(.ui(11)).foregroundStyle(Theme.text3).monospacedDigit().lineLimit(1)
            }
            .padding(.bottom, 4)
            ForEach(period.tips) { tip in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(tip.percent)%").font(.ui(12, .semibold)).monospacedDigit().frame(width: 40, alignment: .trailing)
                    Text(tip.text).font(.ui(12)).frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 6)
                .overlay(alignment: .top) { Rectangle().fill(Theme.line2).frame(height: 1) }
            }
            Button("See ccop's own tips for each session in Spend") { model.openWindow?(nil, .spend) }
                .buttonStyle(.plain)
                .font(.ui(12))
                .foregroundStyle(Theme.accent)
                .padding(.top, 6)
        }
    }

    private var manualEntry: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { manual.toggle() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrowtriangle.right.fill").font(.system(size: 7))
                        .rotationEffect(.degrees(manual ? 90 : 0))
                    Text("Claude Code not found? Type the numbers yourself")
                }
                .foregroundStyle(Theme.accent)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if manual {
                HStack(spacing: 8) {
                    Text("Week")
                    TextField("", text: $percent, prompt: Text("87"))
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .padding(.horizontal, 6)
                        .frame(width: 48, height: 26)
                        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line))
                        .onSubmit(calibrate)
                    Text("%")
                    Text("resets")
                    Picker("", selection: weekday) {
                        ForEach(1...7, id: \.self) { d in Text(Calendar.current.weekdaySymbols[d - 1]).tag(d) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    DatePicker("", selection: resetTime, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .datePickerStyle(.field)
                        .accessibilityLabel("Reset time")
                    Button("Calibrate", action: calibrate)
                        .buttonStyle(DesignButtonStyle(kind: .bordered, height: 26, padding: 10, fontSize: 12))
                        .disabled(model.weekStatus == nil)
                }
                if let message { Text(message).font(.ui(11)).foregroundStyle(Theme.warn) }
            }
        }
        .font(.ui(12))
    }

    /// The reset moment: a weekday and a time; it repeats every 7 days.
    private var anchor: Date { model.plan.resetAnchor ?? Self.nextMonday() }

    private var weekday: Binding<Int> {
        Binding(get: { Calendar.current.component(.weekday, from: anchor) },
                set: { setAnchor(weekday: $0, time: anchor) })
    }

    private var resetTime: Binding<Date> {
        Binding(get: { anchor }, set: { setAnchor(weekday: Calendar.current.component(.weekday, from: anchor), time: $0) })
    }

    private func setAnchor(weekday: Int, time: Date) {
        let cal = Calendar.current
        let hm = cal.dateComponents([.hour, .minute], from: time)
        let match = DateComponents(hour: hm.hour, minute: hm.minute, weekday: weekday)
        model.plan.resetAnchor = cal.nextDate(after: Date(), matching: match, matchingPolicy: .nextTime) ?? time
    }

    private func box<Content: View>(spacing: CGFloat, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: spacing, content: content)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.bg, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line2))
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
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: PlanSettingsView.size),
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
