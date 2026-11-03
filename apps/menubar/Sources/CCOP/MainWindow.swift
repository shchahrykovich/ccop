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
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        model.windowOpen = true
    }

    private func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "ccop"
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
        NavigationSplitView {
            SessionListView(selectedID: model.windowSelectedID, inWindow: true) { model.windowSelectedID = $0 }
                .navigationSplitViewColumnWidth(min: 340, ideal: 420, max: 560)
        } detail: {
            if let s = model.windowSelected {
                WindowDetail(session: s)
            } else {
                Text("Choose a session").foregroundStyle(.secondary)
            }
        }
    }
}

/// One session in the window: a header and the three tabs.
struct WindowDetail: View {
    @Environment(AppModel.self) private var model
    let session: Session

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if session.active {
                    Circle().fill(Theme.ok).frame(width: 8, height: 8)
                        .background(Circle().fill(Theme.ok.opacity(0.2)).frame(width: 14, height: 14))
                        .help("Active")
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Text([session.projectName, session.gitBranch].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .help(session.title)
                Spacer(minLength: 12)
                Picker("View", selection: $model.windowTab) {
                    ForEach(DetailTab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 460)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            switch model.windowTab {
            case .overview:
                SessionDetailView(session: session, inWindow: true)
            case .spend, .chat, .anatomy, .context:
                AnatomyLoader(session: session, tab: model.windowTab)
            }
        }
    }
}

/// Loads the anatomy when shown, and shows Anatomy or Context when it is there.
struct AnatomyLoader: View {
    @Environment(AppModel.self) private var model
    let session: Session
    let tab: DetailTab

    var body: some View {
        Group {
            switch model.anatomies[session.id] {
            case let .loaded(a, at):
                VStack(spacing: 0) {
                    switch tab {
                    case .spend: SpendView(session: session, anatomy: a)
                    case .chat: ChatView(session: session, anatomy: a)
                    case .anatomy: AnatomyView(session: session, anatomy: a)
                    default: ContextView(anatomy: a)
                    }
                    HStack {
                        Text("Read \(Format.ago(at, now: model.now))").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Reload") { model.loadAnatomy(session, reload: true) }.controlSize(.small)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                }
            case let .failed(why):
                VStack(spacing: 8) {
                    Label(why, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).textSelection(.enabled)
                    Button("Try again") { model.loadAnatomy(session, reload: true) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loading, nil:
                ProgressView("Reading the session…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: "\(session.id) \(session.modifiedAt.timeIntervalSince1970)") { model.loadAnatomy(session) }
    }
}
