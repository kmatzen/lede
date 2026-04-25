import Foundation
import Security

/// One-time migration from the legacy keychain service `com.claudenotif.app`
/// to the current bundle-id-aligned service `com.lede.app`. Copies every
/// generic-password item from old → new and deletes the originals so the
/// move is idempotent on subsequent launches.
///
/// We need this because the Mac App Store path requires Keychain
/// access-groups to match the app's TeamID + BundleID; the legacy service
/// name carries over from the project's pre-rename days.
enum KeychainMigration {
    private static let migratedFlag = "lede.keychain.migrated.v1"

    static func runIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migratedFlag) else { return }

        let legacy = Keychain.legacyService
        let target = Keychain.service

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacy,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        var migrated = 0
        if status == errSecSuccess, let items = result as? [[String: Any]] {
            for item in items {
                guard let account = item[kSecAttrAccount as String] as? String,
                      let data = item[kSecValueData as String] as? Data,
                      let value = String(data: data, encoding: .utf8) else { continue }
                if Keychain.set(value, for: account) {
                    migrated += 1
                }
            }
        } else if status == errSecItemNotFound {
            // Nothing to migrate — fresh install. Just mark the flag.
        } else {
            Log.warn("keychain migration: copy failed status=\(status)")
        }

        // Best-effort delete old service entries.
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacy,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        if migrated > 0 {
            Log.info("keychain migration: moved \(migrated) item(s) from \(legacy) to \(target)")
        }
        defaults.set(true, forKey: migratedFlag)
    }
}
