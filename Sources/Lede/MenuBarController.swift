import Cocoa
import SwiftUI

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

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "bell.badge", accessibilityDescription: "Lede")
            button.target = self
            button.action = #selector(togglePanel(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // Observe unread count to update menu bar title.
        engine.$digest
            .receive(on: RunLoop.main)
            .sink { [weak self] digest in
                self?.updateBadge(digest: digest)
            }
            .store(in: &cancellables)
    }

    private var cancellables = Set<AnyCancellableBox>()

    private func updateBadge(digest: Digest?) {
        guard let button = statusItem.button else { return }
        let count = digest?.items.filter { $0.score >= 7 }.count ?? 0
        button.title = count > 0 ? " \(count)" : ""
    }

    @objc private func togglePanel(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            showMenu()
            return
        }

        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            showPanel(relativeTo: sender)
        }
    }

    private func showPanel(relativeTo button: NSStatusBarButton) {
        guard let buttonWindow = button.window else { return }
        let buttonFrame = buttonWindow.convertToScreen(button.frame)
        let panelSize = panel.frame.size
        let origin = NSPoint(
            x: buttonFrame.midX - panelSize.width / 2,
            y: buttonFrame.minY - panelSize.height - 6
        )
        panel.setFrameOrigin(origin)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        Task { await engine.refreshIfConfigured() }
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Refresh now", action: #selector(refreshNow), keyEquivalent: "r").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettingsAction), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Lede", action: #selector(quit), keyEquivalent: "q").target = self
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

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

// Lightweight Combine sink storage without importing Combine at top level elsewhere.
import Combine
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
