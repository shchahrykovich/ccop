import CCOPKit
import SwiftUI

/// The popover: the session list, or one session's details.
struct MainView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            if let s = model.selected {
                SessionDetailView(session: s, inWindow: false)
            } else {
                SessionListView(selectedID: nil, inWindow: false) { model.selectedID = $0 }
            }
        }
        .background(.background)
    }
}

/// The limits, period, search, totals and the sessions by day. Used in the
/// popover and as the main window's sidebar.
struct SessionListView: View {
    @Environment(AppModel.self) private var model
    /// Highlighted row (the window's selection).
    let selectedID: String?
    let inWindow: Bool
    let select: (String) -> Void

    var body: some View {
        @Bindable var model = model
        let visible = model.visible
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: inWindow ? 10 : 11) {
                HStack(spacing: 4) {
                    Text("Claude Code sessions").font(.headline)
                    Spacer()
                    if model.loading {
                        ProgressView().controlSize(.small).frame(width: 28, height: 28)
                    } else {
                        Button { model.refresh() } label: { Image(systemName: "arrow.clockwise").frame(width: 28, height: 28) }
                            .buttonStyle(.borderless)
                            .help("Refresh")
                            .accessibilityLabel("Refresh")
                    }
                    if !inWindow {
                        Button { model.openWindow?(nil, nil) } label: { Image(systemName: "macwindow").frame(width: 28, height: 28) }
                            .buttonStyle(.borderless)
                            .help("Open in a window")
                            .accessibilityLabel("Open in a window")
                    }
                }
                PlanCards(compact: inWindow)
                Picker("Period", selection: $model.period) {
                    ForEach(Period.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                HStack(spacing: 8) {
                    FolderPicker()
                    TextField("Search title, prompt, branch or id", text: $model.query)
                        .textFieldStyle(.roundedBorder)
                }
                TotalsView(sessions: visible, compact: inWindow)
                if let error = model.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.warn)
                        .textSelection(.enabled)
                }
                UpdateBanner()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            Divider()
            if visible.isEmpty {
                Spacer()
                Text(model.loadedAt == nil && model.error == nil ? "Reading sessions…" : "No sessions")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List {
                    ForEach(SessionList.byDay(visible, now: model.now)) { section in
                        let collapsed = model.collapsedDays.contains(section.title)
                        Section {
                            if !collapsed {
                                ForEach(section.sessions) { s in
                                    SessionRow(session: s, now: model.now, selected: s.id == selectedID,
                                               openWindow: inWindow ? nil : { model.openWindow?(s.id, .overview) })
                                        .contentShape(Rectangle())
                                        .onTapGesture { select(s.id) }
                                        .listRowBackground(s.id == selectedID ? Color.accentColor.opacity(0.18) : Color.clear)
                                        .listRowSeparator(.visible)
                                }
                            }
                        } header: {
                            DayHeader(section: section, collapsed: collapsed) { model.toggleDay(section.title) }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
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
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .help("Download \(release.version), quit, and open the new version")
                Button { model.dismissUpdateMessage() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Hide until the next check")
                    .accessibilityLabel("Hide until the next check")
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        case let .downloading(release):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Downloading ccop \(release.version)…")
            }
            .font(.callout)
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
            .font(.caption)
        case .idle, .checking, .upToDate:
            EmptyView()
        }
    }
}

/// A day's title with its session count and tokens; a click closes or opens it.
struct DayHeader: View {
    let section: DaySection
    let collapsed: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                    .font(.caption.weight(.semibold))
                    .frame(width: 10)
                Text(section.title).fontWeight(.semibold)
                if collapsed {
                    Text("\(section.sessions.count) session\(section.sessions.count == 1 ? "" : "s")")
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Text(Format.tokens(section.usage.total)).monospacedDigit().foregroundStyle(.primary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(collapsed ? "Show the sessions of \(section.title)" : "Hide the sessions of \(section.title)")
    }
}

/// Tokens, cost, and the split of the tokens by kind.
struct TotalsView: View {
    let sessions: [Session]
    var compact = false

    var body: some View {
        let u = SessionList.total(sessions)
        let cost = sessions.reduce(UInt64(0)) { $0 + $1.costMicros }
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Format.tokens(u.total)).font(.system(size: compact ? 17 : 22, weight: .semibold)).monospacedDigit()
                Text("tokens in \(sessions.count) session\(sessions.count == 1 ? "" : "s")").foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Text(Format.dollars(cost)).font(.callout.weight(.semibold)).monospacedDigit()
                if !compact {
                    Text("API-equivalent").font(.caption).foregroundStyle(.secondary)
                }
            }
            UsageBar(usage: u, legend: !compact)
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
        VStack(alignment: .leading, spacing: 5) {
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
            .clipShape(Capsule())
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
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
    }
}

/// One session: a click shows it in the popover (or the window); the button
/// opens it in the main window.
struct SessionRow: View {
    let session: Session
    let now: Date
    var selected = false
    /// Nil in the window's sidebar.
    var openWindow: (() -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Circle()
                .fill(session.active ? Theme.ok : Color.clear)
                .frame(width: 7, height: 7)
                .background(Circle().fill(session.active ? Theme.ok.opacity(0.2) : .clear).frame(width: 13, height: 13))
                .frame(width: 13)
                .help(session.active ? "Active: its transcript changed in the last 2 minutes" : "")
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title).lineLimit(1)
                HStack(spacing: 4) {
                    Text(session.projectName)
                    if let b = session.gitBranch { Text("· \(b)") }
                    Text("· \(Format.ago(session.lastActivity, now: now))")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(Format.tokens(session.usage.total)).monospacedDigit().fontWeight(.medium)
                Text(subline).font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
            if let openWindow {
                Button(action: openWindow) {
                    Image(systemName: "macwindow").font(.system(size: 12)).frame(width: 26, height: 26)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Open in the main window")
                .accessibilityLabel("Open \(session.title) in the main window")
            }
        }
        .padding(.vertical, 3)
    }

    private var subline: String {
        guard session.usage.total > 0 else { return "" }
        return "\(Format.dollars(session.costMicros)) · cache \(Format.percent(session.usage.cacheHitRatio))"
    }
}
