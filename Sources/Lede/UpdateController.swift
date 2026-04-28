import Foundation
import Sparkle

/// Sparkle-backed updater for direct distribution (notarized .dmg).
///
/// Reads `SUFeedURL` and `SUPublicEDKey` from Info.plist. Both must be
/// populated before shipping; the placeholder values that ship in the
/// repo's Info.plist make Sparkle silently no-op.
///
/// For Mac App Store builds this controller is still constructed (it's
/// cheap), but the auto-check is disabled because Apple handles updates.
final class UpdateController: NSObject {
    static let shared = UpdateController()

    private let updater: SPUStandardUpdaterController

    override init() {
        // .startingUpdater = true → does the first check shortly after launch.
        // We pass nil delegates; SPUStandardUserDriver provides the default UI.
        self.updater = SPUStandardUpdaterController(
            startingUpdater: !UpdateController.isAppStoreBuild(),
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        super.init()
    }

    /// Wire a "Check for Updates…" menu item to this.
    @objc func checkForUpdates(_ sender: Any?) {
        updater.checkForUpdates(sender)
    }

    /// App Store builds carry an actual MASReceipt file at
    /// Contents/_MASReceipt/receipt; direct-distribution builds don't.
    /// `Bundle.main.appStoreReceiptURL` returns that *expected* path on every
    /// macOS app whether or not the file exists, so checking the path alone
    /// matches the App Store path for every build — which would leave
    /// Sparkle's updater unstarted on the DMG and silently break auto-update.
    /// Stat the file instead.
    private static func isAppStoreBuild() -> Bool {
        guard let receipt = Bundle.main.appStoreReceiptURL else { return false }
        return FileManager.default.fileExists(atPath: receipt.path)
    }
}
