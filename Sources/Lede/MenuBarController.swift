import Cocoa
import SwiftUI
import Combine

@MainActor
final class MenuBarController: NSObject, NSWindowDelegate {
    private let statusItem: NSStatusItem
    private let panel: PinnedPanel
    private let engine: CoreEngine
    private let onOpenSettings: () -> Void

    init(engine: CoreEngine, onOpenSettings: @escaping () -> Void) {
        self.engine = engine
        self.onOpenSettings = onOpenSettings
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let view = PanelView(engine: engine, onOpenSettings: onOpenSettings)
        self.panel = PinnedPanel(rootView: view)

        super.init()
        panel.delegate = self

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePanel(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
        }
        updateBadge(digest: nil)

        engine.$digest
            .receive(on: RunLoop.main)
            .sink { [weak self] digest in
                self?.updateBadge(digest: digest)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .ledePinStateChanged)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.onPinStateChanged()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .ledeSnoozeChanged)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateBadge(digest: self?.engine.digest)
            }
            .store(in: &cancellables)
    }

    private var cancellables = Set<AnyCancellableBox>()
    private var outsideClickMonitor: Any?

    // MARK: Badge

    /// Menu-bar icon state keyed to the highest-priority tier present:
    ///   critical (≥9) → red `bell.badge.fill`
    ///   high (≥6)     → template `bell.badge`
    ///   none          → plain template `bell`
    /// Count text only appears when there's something worth showing.
    private func updateBadge(digest: Digest?) {
        guard let button = statusItem.button else { return }
        let snoozed = Snooze.isActive
        let items = digest?.items ?? []
        let criticalCount = items.filter { $0.score >= 9 }.count
        let highCount = items.filter { $0.score >= 6 }.count

        let symbol: String
        let tint: NSColor?
        let title: String

        if snoozed {
            // Z-bell to indicate snooze. Stays template so it dims to gray
            // alongside the menu bar's text color.
            symbol = "bell.slash"
            tint = nil
            title = ""
        } else if criticalCount > 0 {
            symbol = "bell.badge.fill"
            tint = .systemRed
            title = " \(criticalCount)"
        } else if highCount > 0 {
            symbol = "bell.badge"
            tint = nil
            title = " \(highCount)"
        } else {
            symbol = "bell"
            tint = nil
            title = ""
        }

        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Lede")
        // Template images pick up the menu bar's text color automatically. When
        // we want our own color (critical red), turn off template.
        image?.isTemplate = (tint == nil)
        button.image = image
        button.contentTintColor = tint
        button.title = title
    }

    // MARK: Toggle / show / hide

    @objc private func togglePanel(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            showMenu()
            return
        }

        if panel.isVisible {
            hidePanel()
        } else {
            showPanel(relativeTo: sender)
        }
    }

    private func showPanel(relativeTo button: NSStatusBarButton) {
        if panel.isPinned, let saved = savedPanelOrigin() {
            panel.setFrameOrigin(saved)
        } else {
            positionBelowButton(button)
        }
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Only auto-hide when the user hasn't pinned the panel. Pinned panels
        // stay put across app-switches like a normal window.
        if !panel.isPinned {
            installOutsideClickMonitor()
        }
        Task { await engine.refreshIfConfigured() }
    }

    private func positionBelowButton(_ button: NSStatusBarButton) {
        guard let buttonWindow = button.window else { return }
        let buttonFrame = buttonWindow.convertToScreen(button.frame)
        let size = panel.frame.size
        let origin = NSPoint(
            x: buttonFrame.midX - size.width / 2,
            y: buttonFrame.minY - size.height - 6
        )
        panel.setFrameOrigin(origin)
    }

    private func hidePanel() {
        panel.orderOut(nil)
        removeOutsideClickMonitor()
    }

    /// When a pinned panel's position changes, remember it so the next show
    /// restores where the user dragged it.
    nonisolated func windowDidMove(_ notification: Notification) {
        Task { @MainActor [weak self] in
            guard let self, let window = notification.object as? PinnedPanel, window === self.panel else { return }
            if self.panel.isPinned {
                self.savePanelOrigin(self.panel.frame.origin)
            }
        }
    }

    /// React to the pin state changing (published from PanelView's toggle).
    func onPinStateChanged() {
        if panel.isPinned {
            // Pinning makes the panel behave like a regular window; drop the
            // click-outside monitor so it stops auto-hiding.
            removeOutsideClickMonitor()
            // Seed the saved origin from the current position so subsequent
            // windowDidMove updates are relative to where we started.
            savePanelOrigin(panel.frame.origin)
        } else {
            // Unpinning + panel visible → reinstall the auto-hide.
            if panel.isVisible {
                installOutsideClickMonitor()
            }
        }
    }

    private func savedPanelOrigin() -> NSPoint? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "panel.originX") != nil else { return nil }
        let x = defaults.double(forKey: "panel.originX")
        let y = defaults.double(forKey: "panel.originY")
        return NSPoint(x: x, y: y)
    }

    private func savePanelOrigin(_ origin: NSPoint) {
        UserDefaults.standard.set(Double(origin.x), forKey: "panel.originX")
        UserDefaults.standard.set(Double(origin.y), forKey: "panel.originY")
    }

    // MARK: Click-outside monitor

    private func installOutsideClickMonitor() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in self?.hidePanel() }
        }
    }

    private func removeOutsideClickMonitor() {
        if let m = outsideClickMonitor {
            NSEvent.removeMonitor(m)
            outsideClickMonitor = nil
        }
    }

    // MARK: Right-click menu

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Refresh now", action: #selector(refreshNow), keyEquivalent: "r").target = self
        menu.addItem(.separator())

        // Snooze submenu — current state on top, durations below.
        let snoozeItem = NSMenuItem(title: snoozeMenuTitle(), action: nil, keyEquivalent: "")
        let sub = NSMenu(title: "Snooze")
        if Snooze.isActive {
            sub.addItem(withTitle: "Wake up", action: #selector(snoozeWake), keyEquivalent: "").target = self
            sub.addItem(.separator())
        }
        sub.addItem(withTitle: "30 minutes", action: #selector(snooze30m), keyEquivalent: "").target = self
        sub.addItem(withTitle: "1 hour", action: #selector(snooze1h), keyEquivalent: "").target = self
        sub.addItem(withTitle: "Until tomorrow morning", action: #selector(snoozeTomorrow), keyEquivalent: "").target = self
        snoozeItem.submenu = sub
        menu.addItem(snoozeItem)
        menu.addItem(.separator())

        menu.addItem(withTitle: "Settings…", action: #selector(openSettingsAction), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Check for Updates…",
                     action: #selector(UpdateController.checkForUpdates(_:)),
                     keyEquivalent: "").target = UpdateController.shared
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Lede", action: #selector(quit), keyEquivalent: "q").target = self
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func snoozeMenuTitle() -> String {
        if let until = Snooze.until {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            return "Snoozed (resumes \(formatter.localizedString(for: until, relativeTo: Date())))"
        }
        return "Snooze"
    }

    @objc private func snooze30m() { Snooze.snooze(for: 30 * 60) }
    @objc private func snooze1h() { Snooze.snooze(for: 60 * 60) }
    @objc private func snoozeTomorrow() { Snooze.snoozeUntilTomorrowMorning() }
    @objc private func snoozeWake() { Snooze.wake() }

    @objc private func refreshNow() {
        Task { await engine.refresh(force: true) }
    }

    @objc private func openSettingsAction() {
        onOpenSettings()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

// Lightweight Combine sink storage.
final class AnyCancellableBox: Hashable {
    let inner: AnyCancellable
    init(_ c: AnyCancellable) { self.inner = c }
    static func == (lhs: AnyCancellableBox, rhs: AnyCancellableBox) -> Bool { lhs === rhs }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

extension AnyCancellable {
    func store(in set: inout Set<AnyCancellableBox>) {
        set.insert(AnyCancellableBox(self))
    }
}

extension Notification.Name {
    static let ledePinStateChanged = Notification.Name("lede.pin-state-changed")
}
