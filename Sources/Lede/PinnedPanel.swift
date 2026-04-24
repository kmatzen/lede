import Cocoa
import SwiftUI

/// Borderless floating panel.
///   - Unpinned (default): popover — opens below the bell, hides on outside click.
///   - Pinned: stays visible across app-switches, drag from any background point,
///     position is remembered in UserDefaults.
/// Pin state lives in UserDefaults so PanelView's Toggle and MenuBarController
/// can both read it without passing objects around.
final class PinnedPanel: NSPanel {
    static let pinDefaultsKey = "panel.pinned"

    var isPinned: Bool {
        UserDefaults.standard.bool(forKey: Self.pinDefaultsKey)
    }

    init<Content: View>(rootView: Content) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 540),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        minSize = NSSize(width: 360, height: 320)

        contentView?.wantsLayer = true
        contentView?.layer?.cornerRadius = 12
        contentView?.layer?.masksToBounds = true

        let host = NSHostingView(rootView: rootView)
        host.autoresizingMask = [.width, .height]
        host.frame = contentView?.bounds ?? .zero
        contentView?.addSubview(host)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
