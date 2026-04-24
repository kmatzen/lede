import Foundation
import ServiceManagement

/// Wrapper around `SMAppService.mainApp` (macOS 13+) for the launch-at-login
/// toggle in Settings. `register()` adds the app to the user's login items;
/// `unregister()` removes it. The OS handles persistence and per-user state.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @discardableResult
    static func setEnabled(_ on: Bool) -> Bool {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            Log.error("launch-at-login \(on): \(error)")
            return false
        }
    }
}
