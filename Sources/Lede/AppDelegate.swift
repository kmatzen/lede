import Cocoa
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var menuBar: MenuBarController!
    var engine: CoreEngine!
    var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Crash + Keychain migration before anything else creates state.
        CrashHandler.install()
        KeychainMigration.runIfNeeded()
        Notifier.registerDelegate()

        let storage = Storage.shared
        engine = CoreEngine(storage: storage)
        menuBar = MenuBarController(engine: engine, onOpenSettings: { [weak self] in
            self?.openSettings()
        })
        installEditMenu()

        // First-run: if nothing is configured yet, pop the panel itself so the
        // user sees the Welcome step list — friendlier than dropping them in
        // a tab list with no context.
        if !engine.hasClaudeCreds() || !engine.hasAnySource() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.menuBar.openPanelOnLaunch()
            }
        }

        // Kick off an initial refresh if credentials exist + start the
        // 5-minute background refresh so the bell stays current.
        Task { await engine.refreshIfConfigured() }
        engine.startBackgroundRefresh()

        // Initialize Sparkle (does an initial appcast check shortly after
        // launch unless this is a Mac App Store build).
        _ = UpdateController.shared
    }

    /// An `.accessory` app has no main menu by default, which means the standard
    /// Cmd+V / Cmd+C / Cmd+A shortcuts aren't wired to the first responder and
    /// TextField paste silently fails. Install a minimal Edit menu that forwards
    /// these actions through the responder chain.
    private func installEditMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Lede",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo",
                         action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo",
                                    action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut",
                         action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy",
                         action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste",
                         action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All",
                         action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }

    func openSettings() {
        // Promote to .regular so Settings shows up in Cmd+Tab (and gets a Dock
        // icon temporarily). We revert to .accessory in windowWillClose.
        NSApp.setActivationPolicy(.regular)

        if let w = settingsWindow {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = SettingsView(engine: engine)
        let host = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: host)
        window.title = "Lede Settings"
        window.setContentSize(NSSize(width: 520, height: 560))
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = window
    }

    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow, w === settingsWindow else { return }
        // Drop the Dock icon + Cmd+Tab entry when the user closes Settings.
        NSApp.setActivationPolicy(.accessory)
    }
}
