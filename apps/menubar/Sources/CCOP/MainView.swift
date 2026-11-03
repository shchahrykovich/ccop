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

/// The period, search, totals and the sessions by day. Used in the popover
/// and as the main window's sidebar.
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
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Claude Code sessions").font(.headline)
                    Spacer()
                    if model.loading {
                        ProgressView().controlSize(.small)
                    } else {
                        Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.borderless)
                            .help("Refresh")
                    }
                    if !inWindow {
                        Button { model.openWindow?(nil, nil) } label: { Image(systemName: "macwindow") }
                            .buttonStyle(.borderless)
                            .help("Open in a window")
                    }
                }
                PlanView()
                Divider()
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
                TotalsView(sessions: visible)
                if let error = model.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
                UpdateBanner()
            }
            .padding(12)
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
                                    SessionRow(session: s, now: model.now)
                                        .contentShape(Rectangle())
                                        .onTapGesture { select(s.id) }
                                        .listRowBackground(s.id == selectedID ? Color.accentColor.opacity(0.18) : Color.clear)
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
                    .help("Download \(release.version), quit, and open the new version")
                Button { model.dismissUpdateMessage() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Hide until the next check")
            }
            .font(.callout)
        case let .downloading(release):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Downloading ccop \(release.version)…")
            }
            .font(.callout)
        case let .failed(why):
            HStack(alignment: .top) {
                Label("Could not update: \(why)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                Spacer()
                Button { model.dismissUpdateMessage() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
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
                Text(section.title)
                if collapsed {
                    Text("\(section.sessions.count) session\(section.sessions.count == 1 ? "" : "s")")
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Text(Format.tokens(section.usage.total)).monospacedDigit()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(collapsed ? "Show the sessions of \(section.title)" : "Hide the sessions of \(section.title)")
    }
}

/// Sessions, tokens and the split of the tokens by kind.
struct TotalsView: View {
    let sessions: [Session]

    var body: some View {
        let u = SessionList.total(sessions)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(Format.tokens(u.total)).font(.title2.weight(.semibold)).monospacedDigit()
                Text("tokens in \(sessions.count) session\(sessions.count == 1 ? "" : "s")").foregroundStyle(.secondary)
                Spacer()
                Text("\(Format.percent(u.cacheHitRatio)) of input from cache")
                    .font(.caption).foregroundStyle(.secondary)
            }
            UsageBar(usage: u)
        }
    }
}

/// A bar split by kind of token, with a legend.
struct UsageBar: View {
    let usage: TokenUsage

    static let kinds: [(String, Color, KeyPath<TokenUsage, UInt64>)] = [
        ("Input", .blue, \.inputTokens),
        ("Cache write", .orange, \.cacheWriteTokens),
        ("Cache read", .green, \.cacheReadTokens),
        ("Output", .purple, \.outputTokens),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
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
            .frame(height: 6)
            .clipShape(Capsule())
            HStack(spacing: 10) {
                ForEach(Self.kinds, id: \.0) { kind in
                    HStack(spacing: 4) {
                        Circle().fill(kind.1).frame(width: 7, height: 7)
                        Text("\(kind.0) \(Format.tokens(usage[keyPath: kind.2]))").monospacedDigit()
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

struct SessionRow: View {
    let session: Session
    let now: Date

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(session.active ? Color.green : Color.clear)
                .frame(width: 7, height: 7)
                .padding(.top, 5)
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
                Text(session.usage.total > 0 ? "cache \(Format.percent(session.usage.cacheHitRatio))" : "")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(.vertical, 2)
    }
}
