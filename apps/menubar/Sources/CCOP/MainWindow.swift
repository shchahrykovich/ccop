import AppKit
import CCOPKit
import SwiftUI

/// The main window: the session list beside one session's Overview, Anatomy
/// and Context. While it is open the app has a Dock icon and is in ⌘-Tab;
/// when it closes the app is a menu bar app again.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    private unowned let model: AppModel
    private var window: NSWindow?

    init(model: AppModel) {
        self.model = model
    }

    func show(session: String?, tab: DetailTab?) {
        if let session { model.windowSelectedID = session }
        if let tab { model.windowTab = tab }
        if model.windowSelectedID == nil { model.windowSelectedID = model.visible.first?.id }
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.setActivationPolicy(.regular)
        window.raiseOverOtherApps()
        NSApp.activate()
        // No text field gets the focus by itself.
        DispatchQueue.main.async { window.makeFirstResponder(nil) }
        model.windowOpen = true
    }

    private func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "ccop"
        // The sidebar reaches the top, with the window buttons in it.
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.minSize = NSSize(width: 900, height: 560)
        w.isReleasedWhenClosed = false
        let host = NSHostingController(rootView: WindowRootView().environment(model))
        // Without this the window shrinks to the content's smallest size.
        host.sizingOptions = []
        w.contentViewController = host
        w.setContentSize(NSSize(width: 1280, height: 820))
        w.setFrameAutosaveName("ccop.main")
        if !w.setFrameUsingName("ccop.main") { w.center() }
        w.delegate = self
        return w
    }

    func windowWillClose(_ notification: Notification) {
        model.windowOpen = false
        NSApp.setActivationPolicy(.accessory)
    }
}

struct WindowRootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(selectedID: model.windowSelected?.id) { model.chooseInWindow($0) }
            Group {
                if let s = model.windowShown {
                    WindowDetail(session: s)
                } else {
                    Text("Choose a session").foregroundStyle(Theme.text3).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.bg)
        }
        .foregroundStyle(Theme.text)
        .font(.ui(13))
        // The sidebar reaches the top, under the window buttons.
        .ignoresSafeArea()
    }
}

/// One session in the window: a header with the tabs, then the tab. The tab
/// shows `session`, as it was when the user came to the tab; the header has
/// the newest name and state.
struct WindowDetail: View {
    @Environment(AppModel.self) private var model
    let session: Session

    var body: some View {
        @Bindable var model = model
        let latest = model.windowSelected ?? session
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                WindowHistoryButtons()
                if latest.active {
                    ActiveDot(size: 8).help("Active")
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(latest.title).font(.ui(15, .semibold)).lineLimit(1)
                    Text([latest.projectName, latest.gitBranch].compactMap { $0 }.joined(separator: " · "))
                        .font(.ui(11)).foregroundStyle(Theme.text3).lineLimit(1)
                }
                .help(latest.title)
                FlagButton(session: latest)
                Spacer(minLength: 12)
                WindowUpdateButton()
                Segmented(options: DetailTab.allCases.map { ($0, $0.title) }, selection: $model.windowTab,
                          height: 24, equalWidths: false, radius: 8)
                    .fixedSize()
                    .accessibilityLabel("Session views")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .frame(minHeight: 44)
            .titleBarArea()
            Rectangle().fill(Theme.line).frame(height: 1)
            switch model.windowTab {
            case .overview:
                SessionDetailView(session: session)
            case .spend, .cause, .chat, .anatomy, .context:
                AnatomyLoader(session: session, tab: model.windowTab)
            }
        }
    }
}

/// Says that the session has new data the tab does not show yet; a click shows it.
private struct WindowUpdateButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.windowUpdating, case .loaded = model.windowAnatomy {
            ProgressView()
                .controlSize(.small)
                .frame(width: 28, height: 28)
                .help("Reading the new data…")
        } else if model.windowHasUpdates {
            let count = model.windowUpdateCount
            let help = Self.help(count)
            Button { model.showLatestInWindow() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
                    if count > 0 {
                        Text(Format.changes(count)).font(.ui(12, .semibold)).monospacedDigit()
                    }
                }
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 8)
                .frame(minWidth: 28, minHeight: 24)
                .background(Theme.accent.opacity(0.12), in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .help(help)
            .accessibilityLabel(help)
        }
    }

    private static func help(_ count: UInt64) -> String {
        switch count {
        case 0: "Updates available."
        case 1: "Updates available: 1 new model call or prompt."
        default: "Updates available: \(count.formatted()) new model calls and prompts."
        }
    }
}

/// Back and Forward: the places the window showed before and after this one.
private struct WindowHistoryButtons: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            button("chevron.left", "Back", key: "[", enabled: model.windowHistory.canGoBack) { model.goBackInWindow() }
            button("chevron.right", "Forward", key: "]", enabled: model.windowHistory.canGoForward) { model.goForwardInWindow() }
        }
    }

    private func button(_ symbol: String, _ name: String, key: KeyEquivalent, enabled: Bool, action: @escaping () -> Void) -> some View {
        HeaderIconButton(symbol: symbol, help: name, iconSize: 13, action: action)
            .keyboardShortcut(key, modifiers: .command)
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.35)
    }
}

/// Shows Spend, Cause, Chat, Anatomy or Context when the tab's anatomy is there.
struct AnatomyLoader: View {
    @Environment(AppModel.self) private var model
    let session: Session
    let tab: DetailTab

    var body: some View {
        Group {
            switch model.windowAnatomy {
            case let .loaded(a, _):
                switch tab {
                case .spend: SpendView(session: session, anatomy: a)
                case .cause: CauseView(anatomy: a)
                // A new session starts with its own messages, so a place from
                // the history is not looked for in the old session's messages.
                case .chat: ChatView(session: session, anatomy: a).id(session.id)
                case .anatomy: AnatomyView(session: session, anatomy: a)
                // A new session starts with nothing chosen on the charts.
                default: ContextView(session: session, anatomy: a).id(session.id)
                }
            case let .failed(why):
                VStack(spacing: 8) {
                    Label(why, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn).textSelection(.enabled)
                    Button("Try again") { model.showLatestInWindow() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loading, nil:
                ProgressView("Reading the session…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
