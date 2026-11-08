import AppKit
import CCOPKit
import Observation
import SwiftUI

/// The menu bar icon. A left click toggles the popover with the sessions; a
/// right click shows the menu (window, plan, refresh, updates, quit). NSStatusItem + NSPopover instead of
/// SwiftUI's MenuBarExtra, so the popover can be opened
/// from code.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private unowned let model: AppModel
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    /// When the popover last closed. A click on the icon first closes the
    /// popover, then reaches `clicked`; without this check the same click
    /// would open it again.
    private var closedAt = Date.distantPast
    private var outsideClicks: Any?
    private let mainWindow: MainWindowController
    private let planWindow: PlanWindowController

    init(model: AppModel) {
        self.model = model
        mainWindow = MainWindowController(model: model)
        planWindow = PlanWindowController(model: model)
        super.init()
        model.openPlanSettings = { [weak self] in
            self?.popover.performClose(nil)
            DispatchQueue.main.async { self?.planWindow.show() }
        }
        model.openWindow = { [weak self] session, tab in self?.openWindow(session: session, tab: tab) }
        popover.behavior = .transient
        popover.delegate = self
        let content = NSHostingController(rootView: MainView().environment(model).frame(width: 520, height: 640))
        content.sizingOptions = .preferredContentSize
        popover.contentViewController = content
        popover.contentSize = NSSize(width: 520, height: 640)
        if let button = item.button {
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        }
        trackIcon()
    }

    /// Redraws the icon whenever the sessions change.
    private func trackIcon() {
        withObservationTracking {
            drawIcon()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.trackIcon() }
        }
    }

    private func drawIcon() {
        guard let button = item.button else { return }
        let active = model.activeCount
        let symbol = active > 0 ? "bubble.left.and.text.bubble.right.fill" : "bubble.left.and.text.bubble.right"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "ccop")
        image?.isTemplate = true
        let tokens = model.todayTokens
        let week = model.weekStatus
        // With a weekly limit: a battery split by a diagonal. The left part
        // fills with today (of today's allowance: the limit left, spread over
        // the days left), the right part with the week (of the weekly limit).
        // Without a limit: the icon and today's tokens.
        if let week, let today = week.todayOfAllowance {
            button.image = Self.battery(today: week.todayAllowanceMicros == 0 ? 1 : today, week: week.usedFraction ?? 0,
                                        dark: model.isLocalBuild)
            button.attributedTitle = NSAttributedString()
            button.imagePosition = .imageOnly
        } else {
            button.image = image
            button.imagePosition = .imageLeading
            let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .medium)
            button.attributedTitle = tokens > 0
                ? NSAttributedString(string: " " + Format.tokens(tokens), attributes: [.font: font, .baselineOffset: 0.5])
                : NSAttributedString()
        }
        var lines: [String]
        if let week {
            lines = Plan.menuTooltip(week, resets: week.weekEnd.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
        } else {
            lines = ["ccop: \(Format.tokens(tokens)) tokens today"]
        }
        // Only when something is wrong.
        if let error = model.error { lines.append(error) }
        button.toolTip = lines.joined(separator: "\n")
        button.image?.accessibilityDescription = lines.joined(separator: ". ")
    }

    /// A standing battery split by a diagonal line: the left half is today,
    /// the right half the week. Each half has 5 blocks that light up from the
    /// bottom with the used part (0...1, more is full; any use lights one).
    /// Every lit block of a half has one colour, by how many are lit: green
    /// with one, red with all five (`Plan.batteryLevel`). The
    /// outline uses the menu bar's text colour, read when the image is drawn.
    /// `dark`: a near-black body, for a local build, so it can be told from
    /// the release when both run.
    static func battery(today: Double, week: Double, dark: Bool = false) -> NSImage {
        let rows = 5
        let image = NSImage(size: NSSize(width: 16, height: 22), flipped: false) { _ in
            let label = NSColor.labelColor
            let body = NSRect(x: 1.5, y: 0.6, width: 13, height: 19)
            if dark {
                NSColor(white: 0.09, alpha: 1).setFill()
                NSBezierPath(roundedRect: body, xRadius: 2.5, yRadius: 2.5).fill()
            }
            // An unlit block; on the dark body it must not follow a black menu bar text.
            let unlit = dark ? NSColor(white: 1, alpha: 0.2) : label.withAlphaComponent(0.16)
            let inner = body.insetBy(dx: 1.9, dy: 1.9)
            // Half the width of the gap between the halves; the line sits in it.
            let slant: CGFloat = 1.9, gap: CGFloat = 0.85
            let left = NSBezierPath()
            left.move(to: NSPoint(x: inner.minX, y: inner.minY))
            left.line(to: NSPoint(x: inner.midX - slant - gap, y: inner.minY))
            left.line(to: NSPoint(x: inner.midX + slant - gap, y: inner.maxY))
            left.line(to: NSPoint(x: inner.minX, y: inner.maxY))
            left.close()
            let right = NSBezierPath()
            right.move(to: NSPoint(x: inner.midX - slant + gap, y: inner.minY))
            right.line(to: NSPoint(x: inner.maxX, y: inner.minY))
            right.line(to: NSPoint(x: inner.maxX, y: inner.maxY))
            right.line(to: NSPoint(x: inner.midX + slant + gap, y: inner.maxY))
            right.close()
            let rowGap: CGFloat = 1
            let rowHeight = (inner.height - rowGap * CGFloat(rows - 1)) / CGFloat(rows)
            for (half, used) in [(left, today), (right, week)] {
                let (lit, hue) = Plan.batteryLevel(used: used, rows: rows)
                let color = NSColor(hue: hue, saturation: 0.85, brightness: 0.9, alpha: 1)
                for row in 0 ..< rows {
                    NSGraphicsContext.saveGraphicsState()
                    half.addClip()
                    (row < lit ? color : unlit).setFill()
                    NSRect(x: inner.minX, y: inner.minY + CGFloat(row) * (rowHeight + rowGap),
                           width: inner.width, height: rowHeight).fill()
                    NSGraphicsContext.restoreGraphicsState()
                }
            }
            // The diagonal, from the bottom of the body to the top. On the dark
            // body it must stay light even when the menu bar text is black.
            (dark ? NSColor(white: 1, alpha: 0.95) : label.withAlphaComponent(0.85)).setStroke()
            let run = slant * body.height / inner.height
            let diagonal = NSBezierPath()
            diagonal.move(to: NSPoint(x: body.midX - run, y: body.minY))
            diagonal.line(to: NSPoint(x: body.midX + run, y: body.maxY))
            diagonal.lineWidth = 1.1
            diagonal.stroke()
            label.withAlphaComponent(0.85).setStroke()
            let outline = NSBezierPath(roundedRect: body, xRadius: 2.5, yRadius: 2.5)
            outline.lineWidth = 1.1
            outline.stroke()
            label.withAlphaComponent(0.7).setFill()
            NSBezierPath(roundedRect: NSRect(x: body.midX - 2.5, y: body.maxY + 0.3, width: 5, height: 1.7),
                         xRadius: 0.8, yRadius: 0.8).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    @objc private func clicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseDown || event?.modifierFlags.contains(.control) == true {
            popover.performClose(nil)
            RunLoop.main.perform(inModes: [.default]) { MainActor.assumeIsolated { self.showMenu() } }
        } else if popover.isShown {
            popover.performClose(nil)
        } else if Date().timeIntervalSince(closedAt) > 0.3 {
            showPopover()
        }
    }

    func showPopover() {
        guard let button = item.button, !popover.isShown else { return }
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        // The search field does not take the focus by itself.
        DispatchQueue.main.async { [weak self] in self?.popover.contentViewController?.view.window?.makeFirstResponder(nil) }
        model.popoverOpen = true
        // `.transient` misses clicks in other apps once this app is not active.
        outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.popover.performClose(nil) }
        }
    }

    func popoverDidClose(_ notification: Notification) {
        closedAt = Date()
        model.popoverOpen = false
        if let outsideClicks { NSEvent.removeMonitor(outsideClicks) }
        outsideClicks = nil
    }

    func openWindow(session: String?, tab: DetailTab?) {
        popover.performClose(nil)
        // After the popover's close, so its click does not reach the window.
        DispatchQueue.main.async { self.mainWindow.show(session: session, tab: tab) }
    }

    private func showMenu() {
        let menu = NSMenu()
        if case let .available(release) = model.update {
            let install = NSMenuItem(title: "Install ccop \(release.version)…", action: #selector(installClicked), keyEquivalent: "")
            install.target = self
            menu.addItem(install)
            menu.addItem(.separator())
        }
        let about = NSMenuItem(title: "About \(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "ccop") \(model.version)", action: #selector(aboutClicked), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        menu.addItem(.separator())
        let open = NSMenuItem(title: "Open Window", action: #selector(openWindowClicked), keyEquivalent: "o")
        open.target = self
        menu.addItem(open)
        let plan = NSMenuItem(title: "Plan Settings…", action: #selector(planClicked), keyEquivalent: ",")
        plan.target = self
        menu.addItem(plan)
        let refresh = NSMenuItem(title: "Refresh", action: #selector(refreshClicked), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)
        menu.addItem(.separator())
        let help = NSMenuItem(title: "Help", action: #selector(helpClicked), keyEquivalent: "")
        help.target = self
        menu.addItem(help)
        let installCLI = NSMenuItem(title: "Install Command Line Tool…", action: #selector(installCLIClicked), keyEquivalent: "")
        installCLI.target = self
        menu.addItem(installCLI)
        menu.addItem(.separator())
        let check = NSMenuItem(title: "Check for Updates…", action: #selector(checkClicked), keyEquivalent: "")
        check.target = self
        menu.addItem(check)
        let auto = NSMenuItem(title: "Check for Updates Automatically", action: #selector(autoClicked), keyEquivalent: "")
        auto.target = self
        auto.state = model.autoUpdate ? .on : .off
        menu.addItem(auto)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit ccop", action: #selector(quitClicked), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc private func refreshClicked() { model.refresh() }

    @objc private func aboutClicked() {
        AboutPanel.shared.show(nil)
    }
    @objc private func planClicked() { model.openPlanSettings?() }
    @objc private func openWindowClicked() { openWindow(session: nil, tab: nil) }
    @objc private func quitClicked() { NSApp.terminate(nil) }
    @objc private func autoClicked() { model.autoUpdate.toggle() }

    @objc private func helpClicked() {
        if !model.openHelp() {
            alert("The help page is missing", "This build has no help page. scripts/build-app.sh makes it.", warning: true)
        }
    }

    /// Links `ccop` into ~/.local/bin, and says what to do if a terminal will not find it there.
    @objc private func installCLIClicked() {
        let installer = CLIInstaller()
        let link: URL
        do {
            link = try installer.install()
        } catch {
            alert("Could not install the command line tool", error.localizedDescription, warning: true)
            return
        }
        Task { @MainActor in
            let path = await Task.detached(priority: .userInitiated) { CLIInstaller.loginShellPath() }.value
            if let path, installer.isOnPath(path) {
                alert("ccop is installed", "\(link.path) now runs the ccop of this app. To give an agent its instructions, use Copy for Agent, or tell it to run `ccop guide`.")
                return
            }
            let answer = alert("ccop is installed, but a terminal may not find it",
                               "\(link.path) now runs the ccop of this app, but \(installer.binDir.path) is not on the PATH of your login shell. Run this line in a terminal, then open a new one:\n\n\(CLIInstaller.pathHint)",
                               buttons: ["Copy the Line", "Close"])
            if answer == .alertFirstButtonReturn { model.copy(CLIInstaller.pathHint) }
        }
    }

    @objc private func checkClicked() {
        Task { @MainActor in
            await model.checkForUpdates(manual: true)
            switch model.update {
            case let .available(release): offer(release)
            case .upToDate:
                alert("ccop is up to date", "You have version \(model.version), the newest.")
                model.dismissUpdateMessage()
            case let .failed(why):
                alert("Could not check for updates", why, warning: true)
                model.dismissUpdateMessage()
            case .idle, .checking, .downloading: break
            }
        }
    }

    @objc private func installClicked() {
        if case let .available(release) = model.update { offer(release) }
    }

    /// Asks before installing. On success the app quits; it is still here only on failure.
    private func offer(_ release: Updater.Release) {
        let notes = release.notes.isEmpty ? "" : "\n\n\(release.notes)"
        let answer = alert("ccop \(release.version) is available",
                           "You have version \(model.version). Install it now? ccop quits and opens again.\(notes)",
                           buttons: ["Install", "Later"])
        guard answer == .alertFirstButtonReturn else { return }
        Task { @MainActor in
            await model.installUpdate(release)
            if case let .failed(why) = model.update { alert("Could not install the update", why, warning: true) }
        }
    }

    @discardableResult
    private func alert(_ title: String, _ detail: String, warning: Bool = false, buttons: [String] = []) -> NSApplication.ModalResponse {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = warning ? .warning : .informational
        for title in buttons { alert.addButton(withTitle: title) }
        return alert.runModal()
    }
}
