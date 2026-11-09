import AppKit
import CCOPKit
import Charts
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
            .help("Settings")
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
                    fill: part ?? 0, caption: caption)
    }

    private func weekCard(_ s: WeekStatus) -> some View {
        let used = s.usedFraction
        let color = s.tone.map { Color(nsColor: Theme.nsWeek($0)) } ?? Theme.text2
        let reset = s.weekEnd.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        return card(title: "Week", value: used.map(Self.percent) ?? Format.dollars(s.usedMicros), color: color,
                    fill: used ?? 0, ticks: s.dayTicks, today: s.todayOnBar,
                    caption: "\(Format.percent(s.elapsedFraction)) of week passed · resets \(reset)")
    }

    private func card(title: String, value: String, color: Color, fill: Double, ticks: [Double] = [], today: ClosedRange<Double>? = nil,
                      caption: String) -> some View {
        VStack(alignment: .leading, spacing: compact ? 5 : 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title.uppercased()).font(.ui(compact ? 10.5 : 11, .semibold)).tracking(0.44)
                    .foregroundStyle(Theme.text2)
                Spacer()
                Text(value).font(.ui(compact ? 13 : 17, .semibold)).monospacedDigit().foregroundStyle(color)
            }
            Meter(value: fill, color: color, height: compact ? 4 : 5, ticks: ticks, today: today)
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

/// This week against the week before, as two lines of the running total from
/// each week's reset. In the popover, under the two cards.
struct WeekCompareCard: View {
    @Environment(AppModel.self) private var model
    /// Saved: only from the reset to now (the default), or the whole limit week.
    @AppStorage("weekGraphSoFar") private var soFar = true

    private struct Mark: Identifiable {
        var week: String
        var hour: Double
        var value: Double
        var id: String { "\(week) \(hour)" }
    }

    private static let thisWeek = "This week"
    private static let lastWeek = "Last week"

    var body: some View {
        if let (status, c) = model.weekComparison {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    legend(Self.thisWeek, value: text(c.currentTotal, c), dashed: false)
                    legend(Self.lastWeek, value: "\(text(c.previousByNow, c)) by now · \(text(c.previousTotal, c)) in all", dashed: true)
                    Spacer(minLength: 0)
                    Picker("Graph", selection: $soFar) {
                        Text("Whole week").tag(false)
                        Text("So far").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.mini)
                    .fixedSize()
                    .help("Whole week: from the reset of your weekly limit to the next reset. So far: from the reset to now.")
                }
                chart(status, soFar ? c.soFar : c).frame(height: 62)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(Theme.bg, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.line2))
            .help("Your use from each week's reset. The percents use your current weekly limit, for both weeks.")
        }
    }

    /// A percent of the weekly limit; dollars without a limit.
    private func text(_ micros: UInt64, _ c: WeekComparison) -> String {
        if let b = c.budgetMicros, b > 0 { return Format.percent(Double(micros) / Double(b)) }
        return Format.dollars(micros)
    }

    /// The value on the y axis: a part of the limit, or dollars.
    private func value(_ micros: UInt64, _ c: WeekComparison) -> Double {
        if let b = c.budgetMicros, b > 0 { return Double(micros) / Double(b) }
        return Double(micros) / 1e6
    }

    /// The top of the y axis; 1% or $1 before anything is used.
    private func top(_ c: WeekComparison) -> Double {
        let hasLimit = (c.budgetMicros ?? 0) > 0
        return c.peak == 0 ? (hasLimit ? 0.01 : 1) : Plan.axisTop(value(c.peak, c))
    }

    private func marks(_ c: WeekComparison) -> [Mark] {
        // A line is made in order; the hours of one week never repeat.
        c.previous.map { Mark(week: Self.lastWeek, hour: $0.hour, value: value($0.micros, c)) }
            + c.current.map { Mark(week: Self.thisWeek, hour: $0.hour, value: value($0.micros, c)) }
    }

    private func chart(_ status: WeekStatus, _ c: WeekComparison) -> some View {
        let top = top(c)
        // The whole week, or from the reset to now, at least 1 hour wide.
        let hours = soFar ? max(1, c.current.last?.hour ?? 1) : Plan.week / 3600
        let ticks = Plan.axisTicks(from: status.weekStart, hours: hours)
        return Chart {
            ForEach(marks(c)) { m in
                LineMark(x: .value("Hours", m.hour), y: .value("Used", m.value), series: .value("Week", m.week))
                    .foregroundStyle(m.week == Self.thisWeek ? Theme.accent : Theme.text3)
                    .lineStyle(m.week == Self.thisWeek ? StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                        : StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
            }
            if let now = c.current.last {
                PointMark(x: .value("Hours", now.hour), y: .value("Used", value(now.micros, c)))
                    .foregroundStyle(Theme.accent)
                    .symbolSize(22)
            }
        }
        .chartLegend(.hidden)
        .chartXScale(domain: 0.0 ... hours)
        .chartYScale(domain: 0.0 ... top)
        .chartXAxis {
            AxisMarks(values: ticks.hours) { v in
                AxisGridLine().foregroundStyle(Theme.line2)
                AxisValueLabel(anchor: .topLeading) {
                    if let hour = v.as(Double.self) {
                        let date = status.weekStart.addingTimeInterval(hour * 3600)
                        Text(ticks.byDay ? date.formatted(.dateTime.weekday(.abbreviated)) : date.formatted(date: .omitted, time: .shortened))
                            .font(.ui(10)).monospacedDigit().foregroundStyle(Theme.text3)
                    }
                }
            }
        }
        .chartYAxis {
            // At the top left: both lines start low there, so nothing is under the label.
            AxisMarks(position: .leading, values: [top]) { v in
                AxisGridLine().foregroundStyle(Theme.line2)
                AxisValueLabel(anchor: .topLeading) {
                    if let y = v.as(Double.self) {
                        Text(c.budgetMicros ?? 0 > 0 ? Format.smallPercent(y) : Format.dollars(UInt64(y * 1e6)))
                            .font(.ui(10)).monospacedDigit().foregroundStyle(Theme.text3)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("This week \(text(c.currentTotal, c)). Last week \(text(c.previousByNow, c)) by now.")
    }

    private func legend(_ title: String, value: String, dashed: Bool) -> some View {
        HStack(spacing: 5) {
            Path { p in
                p.move(to: CGPoint(x: 0, y: 1))
                p.addLine(to: CGPoint(x: 14, y: 1))
            }
            .stroke(dashed ? Theme.text3 : Theme.accent,
                    style: StrokeStyle(lineWidth: dashed ? 1.2 : 2, dash: dashed ? [3, 3] : []))
            .frame(width: 14, height: 2)
            (Text(title + " ").foregroundStyle(Theme.text2) + Text(value).fontWeight(.semibold).foregroundStyle(Theme.text))
                .font(.ui(11)).monospacedDigit().lineLimit(1)
        }
    }
}

/// The plan window (board "Plan settings"): the limits read from Claude
/// Code, Claude Code's own tips, and a way to type the numbers by hand.
struct PlanSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var percent = ""
    @State private var message: String?
    @State private var manual = false
    @State private var keyMode: ApiKeySetting.Mode?
    @State private var keyDraft = ""

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
            apiKeyRow
        }
    }

    /// The mode shown: the saved one, or Key while a key is being typed.
    private var shownKeyMode: Binding<ApiKeySetting.Mode> {
        Binding(get: { keyMode ?? model.apiKey.mode }, set: { mode in
            keyMode = mode
            switch mode {
            case .shell: model.setApiKey(.shell)
            case .empty: model.setApiKey(.empty)
            case .key: break // saved with the key
            }
        })
    }

    private var apiKeyRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("API key").font(.ui(12))
                Picker("", selection: shownKeyMode) {
                    Text("From shell").tag(ApiKeySetting.Mode.shell)
                    Text("Empty").tag(ApiKeySetting.Mode.empty)
                    Text("Key").tag(ApiKeySetting.Mode.key)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("ANTHROPIC_API_KEY for claude -p /usage")
                Spacer()
            }
            if shownKeyMode.wrappedValue == .key {
                HStack(spacing: 8) {
                    SecureField("", text: $keyDraft,
                                prompt: Text(model.apiKey.mode == .key ? "Saved in the Keychain. Type a new key to change it" : "sk-ant-…"))
                        .textFieldStyle(.plain)
                        .font(.mono(11.5))
                        .padding(.horizontal, 6)
                        .frame(height: 26)
                        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line))
                        .onSubmit(saveKey)
                        .accessibilityLabel("Anthropic API key")
                    Button("Save", action: saveKey)
                        .buttonStyle(DesignButtonStyle(kind: .bordered, height: 26, padding: 10, fontSize: 12))
                        .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            Text(keyHelp(shownKeyMode.wrappedValue))
                .font(.ui(11)).foregroundStyle(Theme.text3).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            if let error = model.apiKeyError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.ui(11)).foregroundStyle(Theme.warn).textSelection(.enabled)
            }
        }
    }

    private func keyHelp(_ mode: ApiKeySetting.Mode) -> String {
        switch mode {
        case .shell: "Claude Code gets ANTHROPIC_API_KEY from your shell, if the shell sets it. With an API key, /usage shows only the cost, not the plan limits."
        case .empty: "ccop runs ANTHROPIC_API_KEY=\"\" claude -p /usage, so Claude Code uses your subscription login."
        case .key: "ccop runs claude -p /usage with this key. The key is kept in the Keychain."
        }
    }

    private func saveKey() {
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        model.setApiKey(.key(key))
        if model.apiKeyError == nil {
            keyDraft = ""
            keyMode = nil
        }
    }

    private var readLine: Text {
        let mono = Text(LimitsReader.shownCommand(model.apiKey)).font(.mono(11.5))
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
                    Text("Claude Code not found? Choose its path or type the numbers")
                }
                .foregroundStyle(Theme.accent)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if manual {
                HStack(spacing: 8) {
                    Text("Path")
                    TextField("", text: Binding(get: { model.claudePath }, set: { model.claudePath = $0 }),
                              prompt: Text("Found by itself, for example ~/.local/bin/claude"))
                        .textFieldStyle(.plain)
                        .font(.mono(11.5))
                        .padding(.horizontal, 6)
                        .frame(height: 26)
                        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line))
                        .onSubmit { model.readLimits() }
                        .accessibilityLabel("Path to Claude Code")
                    Button("Choose…", action: chooseClaude)
                        .buttonStyle(DesignButtonStyle(kind: .bordered, height: 26, padding: 10, fontSize: 12))
                }
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
        // The way out of the error above is in this section.
        .onChange(of: model.limitsError) { _, error in if error != nil { manual = true } }
        .onAppear { if model.limitsError != nil { manual = true } }
    }

    /// Hidden files are shown: Claude Code is often in `~/.local/bin`.
    private func chooseClaude() {
        let panel = NSOpenPanel()
        panel.message = "Choose the claude program"
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.claudePath = url.path
        model.readLimits()
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
            w.title = "Settings"
            w.isReleasedWhenClosed = false
            w.contentViewController = NSHostingController(rootView: PlanSettingsView().environment(model))
            w.center()
            return w
        }()
        window = w
        w.raiseOverOtherApps()
        NSApp.activate()
    }
}
