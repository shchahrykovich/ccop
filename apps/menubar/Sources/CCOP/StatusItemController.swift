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
        button.image = image
        button.imagePosition = .imageLeading
        let tokens = model.todayTokens
        let week = model.weekStatus
        // With a weekly limit: "33%/87%". Today as a percent of today's
        // allowance (the limit left, spread over the days left), colored from
        // green to red; then the week as a percent of the weekly limit, in the
        // menu bar's own color. Without a limit: today's tokens.
        let planLabel = week.flatMap(Plan.menuLabel)
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .medium)
        let base: [NSAttributedString.Key: Any] = [.font: font, .baselineOffset: 0.5]
        let title = NSMutableAttributedString()
        if let planLabel {
            var todayAttributes = base
            if let part = week?.todayOfAllowance {
                todayAttributes[.foregroundColor] = NSColor(hue: Plan.hue(ofAllowance: part), saturation: 0.85, brightness: 0.85, alpha: 1)
            }
            title.append(NSAttributedString(string: " " + planLabel.today, attributes: todayAttributes))
            if let w = planLabel.week {
                title.append(NSAttributedString(string: "/" + w, attributes: base))
            }
        } else if tokens > 0 {
            title.append(NSAttributedString(string: " " + Format.tokens(tokens), attributes: base))
        }
        button.attributedTitle = title
        var tip = "ccop: \(Format.tokens(tokens)) tokens in sessions active today"
        if let week, let part = week.todayOfAllowance, let allowance = week.todayAllowanceMicros,
           let budget = week.budgetMicros, budget > 0, let used = week.usedFraction {
            let todayPart: String = part.isFinite ? Format.percent(part) : "everything"
            let allowancePart: String = Format.percent(Double(allowance) / Double(budget))
            let lines: [String] = [
                "ccop: today used \(todayPart) of today's allowance; the week \(Format.percent(used)) of the weekly limit",
                "Today's allowance: \(allowancePart) of the weekly limit (what is left, spread over the days left)",
                "This week: \(Format.percent(used)) of the limit used, \(Format.percent(week.elapsedFraction)) of the week passed",
                "Resets \(week.weekEnd.formatted(date: .abbreviated, time: .shortened))",
            ]
            tip = lines.joined(separator: "\n")
        }
        if active > 0 { tip += "\n\(active) session\(active == 1 ? "" : "s") active now" }
        if let error = model.error { tip += "\n\(error)" }
        button.toolTip = tip
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
    @objc private func planClicked() { model.openPlanSettings?() }
    @objc private func openWindowClicked() { openWindow(session: nil, tab: nil) }
    @objc private func quitClicked() { NSApp.terminate(nil) }
    @objc private func autoClicked() { model.autoUpdate.toggle() }

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
