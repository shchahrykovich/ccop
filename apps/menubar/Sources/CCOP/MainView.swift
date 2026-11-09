import CCOPKit
import SwiftUI

/// The popover: the session list. A click on a session opens it in the main window.
struct MainView: View {
    var body: some View {
        SessionListView()
            .background(Theme.pop)
            .foregroundStyle(Theme.text)
            .font(.ui(13))
    }
}

/// The popover's list (board "Popover · sessions"): limits, period, folder and
/// search, totals, then the sessions by day.
struct SessionListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let visible = model.visible
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 11) {
                HStack(spacing: 4) {
                    Text("Claude Code sessions").font(.ui(13, .semibold))
                    Spacer()
                    PauseButton()
                    RefreshButton()
                    HeaderIconButton(symbol: "macwindow", help: "Open in a window") { model.openWindow?(nil, nil) }
                    HeaderIconButton(symbol: "gearshape", help: "Settings") { model.openPlanSettings?() }
                }
                PlanCards()
                WeekCompareCard()
                Segmented(options: Period.allCases.map { ($0, $0.title) }, selection: $model.period)
                    .accessibilityLabel("Period")
                SearchField(placeholder: "Search title, prompt, branch or id", text: $model.query, iconSize: 12) {
                    FolderPicker()
                }
                TotalsView(sessions: visible)
                StatusMessages()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            Rectangle().fill(Theme.line).frame(height: 1)
            if visible.isEmpty {
                EmptyList()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(SessionList.byDay(visible, now: model.now)) { section in
                            let collapsed = model.collapsedDays.contains(section.title)
                            Section {
                                if !collapsed {
                                    ForEach(section.sessions) { s in
                                        SessionRow(session: s, now: model.now, flagged: model.flagged.contains(s.id)) {
                                            model.openWindow?(s.id, .overview)
                                        }
                                        .contextMenu { SessionMenu(model: model, session: s) }
                                    }
                                }
                            } header: {
                                DayHeader(section: section, collapsed: collapsed) { model.toggleDay(section.title) }
                            }
                        }
                    }
                }
                .background(Theme.bg)
            }
        }
    }
}

/// The window's sidebar (board "Window sidebar"): the same parts, smaller,
/// on grey; the chosen session is a solid accent plate.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    let selectedID: String?
    let select: (String) -> Void

    var body: some View {
        @Bindable var model = model
        let visible = model.visible
        VStack(spacing: 0) {
            HStack {
                Spacer()
                PauseButton(iconSize: 13)
                RefreshButton(iconSize: 14)
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .titleBarArea()
            VStack(alignment: .leading, spacing: 10) {
                PlanCards(compact: true)
                Segmented(options: SidebarMode.allCases.map { ($0, $0.title) }, selection: $model.sidebarMode, height: 24,
                          symbol: { $0.symbol })
                    .accessibilityLabel("List")
                Segmented(options: Period.allCases.map { ($0, $0.title) }, selection: $model.period)
                    .accessibilityLabel("Period")
                SearchField(placeholder: "Search", text: $model.query, iconSize: 12) {
                    FolderPicker()
                }
                VStack(alignment: .leading, spacing: 6) {
                    let u = SessionList.total(visible)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(Format.tokens(u.total)).font(.ui(17, .semibold)).monospacedDigit()
                        Text("in \(visible.count) session\(visible.count == 1 ? "" : "s")").font(.ui(12)).foregroundStyle(Theme.text2)
                        Spacer()
                        Text(Format.dollars(visible.reduce(0) { $0 + $1.costMicros })).font(.ui(12, .semibold)).monospacedDigit()
                    }
                    UsageBar(usage: u, legend: false, height: 5)
                }
                StatusMessages()
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
            Rectangle().fill(Theme.line).frame(height: 1)
            if model.sidebarMode == .tools {
                ToolsSidebarList()
            } else if visible.isEmpty {
                EmptyList()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(SessionList.byDay(visible, now: model.now)) { section in
                            HStack(spacing: 6) {
                                Text(section.title)
                                Spacer()
                                Text(Format.tokens(section.usage.total)).monospacedDigit()
                            }
                            .font(.ui(11, .semibold))
                            .foregroundStyle(Theme.text3)
                            .padding(.horizontal, 8)
                            .frame(height: 26)
                            ForEach(section.sessions) { s in
                                SidebarRow(session: s, now: model.now, flagged: model.flagged.contains(s.id), selected: s.id == selectedID)
                                    .contentShape(Rectangle())
                                    .onTapGesture { select(s.id) }
                                    .contextMenu { SessionMenu(model: model, session: s) }
                            }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(width: 360)
        .background(Theme.side)
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.line).frame(width: 1) }
        .foregroundStyle(Theme.text)
        .font(.ui(13))
    }
}

/// Refresh, or a spinner while the sessions are read.
private struct RefreshButton: View {
    @Environment(AppModel.self) private var model
    var iconSize: CGFloat = 15

    var body: some View {
        if model.loading {
            ProgressView().controlSize(.small).frame(width: 28, height: 28)
        } else {
            HeaderIconButton(symbol: "arrow.clockwise", help: "Refresh", iconSize: iconSize) { model.refresh() }
        }
    }
}

/// Pauses and resumes the automatic updates. While paused the icon is a
/// play symbol in the accent color.
private struct PauseButton: View {
    @Environment(AppModel.self) private var model
    var iconSize: CGFloat = 14

    var body: some View {
        Button { model.paused.toggle() } label: {
            Image(systemName: model.paused ? "play.fill" : "pause")
                .font(.system(size: iconSize))
                .foregroundStyle(model.paused ? Theme.accent : Theme.text2)
                .frame(width: 28, height: 28)
                .background(model.paused ? Theme.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(model.paused ? "Paused: no automatic updates. Click to resume." : "Pause the automatic updates while you look at the data")
        .accessibilityLabel(model.paused ? "Resume updates" : "Pause updates")
    }
}

private struct EmptyList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Text(message)
            .multilineTextAlignment(.center)
            .foregroundStyle(Theme.text3)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.bg)
    }

    private var message: String {
        if model.loadedAt == nil, model.error == nil { return "Reading sessions…" }
        if model.period == .flagged, model.flagged.isEmpty { return "No flagged sessions.\nRight-click a session to flag it." }
        return "No sessions"
    }
}

/// The right-click menu of a session in a list.
struct SessionMenu: View {
    let model: AppModel
    let session: Session

    var body: some View {
        Button(model.flagged.contains(session.id) ? "Remove Flag" : "Flag") { model.toggleFlag(session) }
        Divider()
        Button("Resume in Terminal") { model.resumeInTerminal(session) }
        Button("Copy Resume Command") { model.copyResumeCommand(session) }
        Button("Copy for Agent") { model.copyForAgent(session) }
        Divider()
        Button("Copy Session ID") { model.copy(session.id) }
        Button("Copy Project Folder Path") { model.copy(session.projectDir) }
        Divider()
        Button("Show Transcript in Finder") { model.revealTranscript(session) }
        Button("Open Project Folder") { model.openProjectFolder(session) }
    }
}

/// The small flag beside the title of a flagged session.
struct FlagMark: View {
    var color: Color = Theme.warn

    var body: some View {
        Image(systemName: "flag.fill")
            .font(.system(size: 9))
            .foregroundStyle(color)
            .accessibilityLabel("Flagged")
            .help("Flagged")
    }
}

/// Flags one session, or removes its flag.
struct FlagButton: View {
    @Environment(AppModel.self) private var model
    let session: Session

    var body: some View {
        let on = model.flagged.contains(session.id)
        let help = on ? "Remove the flag from this session" : "Flag this session, to find it in the Flagged list"
        Button { model.toggleFlag(session) } label: {
            Image(systemName: on ? "flag.fill" : "flag")
                .font(.system(size: 13))
                .foregroundStyle(on ? Theme.warn : Theme.text2)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A read error and the update banner, when there is one.
private struct StatusMessages: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let error = model.error {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.ui(11))
                .foregroundStyle(Theme.warn)
                .textSelection(.enabled)
        }
        UpdateBanner()
    }
}

/// A white field, 26 high, with a magnifier; `trailing` goes inside it on the
/// right (the sidebar's folder picker).
struct SearchField<Trailing: View>: View {
    let placeholder: String
    @Binding var text: String
    var iconSize: CGFloat = 13
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: iconSize - 1)).foregroundStyle(Theme.text3)
                .accessibilityHidden(true)
            TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(Theme.text3))
                .textFieldStyle(.plain)
                .font(.ui(12))
                .accessibilityLabel("Search sessions")
            trailing()
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line))
    }
}

extension SearchField where Trailing == EmptyView {
    init(placeholder: String, text: Binding<String>, iconSize: CGFloat = 13) {
        self.init(placeholder: placeholder, text: text, iconSize: iconSize) { EmptyView() }
    }
}

/// A new version, or its download. Other update results show as alerts
/// from the menu's Check for Updates….
struct UpdateBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.update {
        case let .available(release):
            HStack {
                Label("ccop \(release.version) is available", systemImage: "arrow.down.circle.fill")
                Spacer()
                Button("Install") { Task { await model.installUpdate(release) } }
                    .buttonStyle(DesignButtonStyle(kind: .primary, height: 24, padding: 10, fontSize: 12))
                    .help("Download \(release.version), quit, and open the new version")
                Button { model.dismissUpdateMessage() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Hide until the next check")
                    .accessibilityLabel("Hide until the next check")
            }
            .font(.ui(12))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Theme.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.accent.opacity(0.18)))
        case let .downloading(release):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Downloading ccop \(release.version)…")
            }
            .font(.ui(12))
        case let .failed(why):
            HStack(alignment: .top) {
                Label("Could not update: \(why)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.warn)
                    .textSelection(.enabled)
                Spacer()
                Button { model.dismissUpdateMessage() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Hide")
            }
            .font(.ui(11))
        case .idle, .checking, .upToDate:
            EmptyView()
        }
    }
}

/// A day's title with its tokens, and the session count while it is closed;
/// a click closes or opens it.
struct DayHeader: View {
    let section: DaySection
    let collapsed: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                    .frame(width: 10)
                Text(section.title)
                if collapsed {
                    Text("\(section.sessions.count) session\(section.sessions.count == 1 ? "" : "s")")
                        .fontWeight(.regular)
                        .foregroundStyle(Theme.text3)
                }
                Spacer()
                Text(Format.tokens(section.usage.total)).monospacedDigit().foregroundStyle(Theme.text)
            }
            .font(.ui(12, .semibold))
            .foregroundStyle(Theme.text2)
            .padding(.horizontal, 14)
            .frame(height: 28)
            .background(Theme.pop)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line2).frame(height: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(collapsed ? "Show the sessions of \(section.title)" : "Hide the sessions of \(section.title)")
    }
}

/// Tokens, cost, and the split of the tokens by kind.
struct TotalsView: View {
    let sessions: [Session]

    var body: some View {
        let u = SessionList.total(sessions)
        let cost = sessions.reduce(UInt64(0)) { $0 + $1.costMicros }
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Format.tokens(u.total)).font(.ui(22, .semibold)).tracking(-0.22).monospacedDigit()
                Text("tokens in \(sessions.count) session\(sessions.count == 1 ? "" : "s")").foregroundStyle(Theme.text2)
                    .lineLimit(1)
                Spacer()
                Text(Format.dollars(cost)).font(.ui(13, .semibold)).monospacedDigit()
                Text("API-equivalent").font(.ui(11)).foregroundStyle(Theme.text3)
            }
            UsageBar(usage: u)
        }
    }
}

/// A bar split by kind of token, with a legend.
struct UsageBar: View {
    let usage: TokenUsage
    var legend = true
    var height: CGFloat = 6

    static let kinds: [(String, Color, KeyPath<TokenUsage, UInt64>)] = [
        ("Input", Theme.input, \.inputTokens),
        ("Cache write", Theme.cacheWrite, \.cacheWriteTokens),
        ("Cache read", Theme.cacheRead, \.cacheReadTokens),
        ("Output", Theme.output, \.outputTokens),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(Self.kinds, id: \.0) { kind in
                        let n = usage[keyPath: kind.2]
                        if n > 0, usage.total > 0 {
                            Rectangle().fill(kind.1)
                                .frame(width: max(2, geo.size.width * CGFloat(n) / CGFloat(usage.total)))
                        }
                    }
                }
            }
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: height / 2))
            .accessibilityHidden(true)
            if legend {
                HStack(spacing: 10) {
                    ForEach(Self.kinds, id: \.0) { kind in
                        HStack(spacing: 4) {
                            Circle().fill(kind.1).frame(width: 7, height: 7)
                            Text("\(kind.0) \(Format.tokens(usage[keyPath: kind.2]))").monospacedDigit()
                        }
                        .fixedSize()
                    }
                    Spacer(minLength: 4)
                    Text("cache \(Format.percent(usage.cacheHitRatio))").monospacedDigit().fixedSize()
                }
                .font(.ui(11))
                .foregroundStyle(Theme.text2)
                .lineLimit(1)
            }
        }
    }
}

/// One session in the popover: a click shows it in the popover; the button
/// opens it in the main window.
struct SessionRow: View {
    let session: Session
    let now: Date
    var flagged = false
    let open: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: open) {
                HStack(alignment: .top, spacing: 8) {
                    dot.padding(.top, 5)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(session.title).lineLimit(1)
                            if flagged { FlagMark() }
                        }
                        Text(meta).font(.ui(11)).foregroundStyle(Theme.text3).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(Format.tokens(session.usage.total)).fontWeight(.medium)
                        Text(subline).font(.ui(11)).foregroundStyle(Theme.text3).lineLimit(1)
                    }
                    .monospacedDigit()
                }
                .padding(.leading, 12)
                .padding(.trailing, 4)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open this session in the main window")
        }
        .padding(.trailing, 14)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line2).frame(height: 1) }
    }

    @ViewBuilder private var dot: some View {
        if session.active {
            ActiveDot().help("Active: its transcript changed in the last 2 minutes")
        } else {
            Color.clear.frame(width: 7, height: 7)
        }
    }

    private var meta: String {
        ([session.projectName, session.gitBranch].compactMap { $0 } + [Format.ago(session.lastActivity, now: now)])
            .joined(separator: " · ")
    }

    private var subline: String {
        guard session.usage.total > 0 else { return "" }
        return "\(Format.dollars(session.costMicros)) · cache \(Format.percent(session.usage.cacheHitRatio))"
    }
}

/// One session in the window's sidebar.
struct SidebarRow: View {
    let session: Session
    let now: Date
    var flagged = false
    let selected: Bool

    var body: some View {
        let secondary: Color = selected ? .white.opacity(0.85) : Theme.text3
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(session.active ? (selected ? Color.white : Theme.ok) : .clear)
                .frame(width: 7, height: 7)
                .padding(.top, 5)
                .help(session.active ? "Active: its transcript changed in the last 2 minutes" : "")
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(session.title).lineLimit(1)
                    if flagged { FlagMark(color: selected ? .white : Theme.warn) }
                }
                Text(([session.projectName, session.gitBranch].compactMap { $0 } + [Format.ago(session.lastActivity, now: now)])
                    .joined(separator: " · "))
                    .font(.ui(11)).foregroundStyle(secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text(Format.tokens(session.usage.total)).fontWeight(.medium)
                Text(session.usage.total > 0 ? Format.dollars(session.costMicros) : "").font(.ui(11)).foregroundStyle(secondary)
            }
            .monospacedDigit()
        }
        .foregroundStyle(selected ? Color.white : Theme.text)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(selected ? Theme.accent : .clear, in: RoundedRectangle(cornerRadius: 7))
    }
}

private extension SidebarMode {
    var symbol: String {
        switch self {
        case .sessions: "list.bullet.rectangle"
        case .tools: "wrench.and.screwdriver"
        }
    }
}
