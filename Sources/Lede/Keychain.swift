import Foundation
import Security

enum Keychain {
    static let service = "com.lede.app"
    static let legacyService = "com.claudenotif.app"

    @discardableResult
    static func set(_ value: String, for key: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let attrs: [String: Any] = [kSecValueData as String: data]

        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func delete(_ key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }

    // MARK: Well-known keys
    enum Key {
        // Anthropic — single instance, not per-account.
        static let anthropicAPIKey = "anthropic.api_key"
        static let anthropicOAuthAccess = "anthropic.oauth.access"
        static let anthropicOAuthRefresh = "anthropic.oauth.refresh"
        static let anthropicOAuthExpiry = "anthropic.oauth.expiry"

        // Per-account keys are suffixed with the account's provider-stable id
        // (e.g. "google.oauth.access:user@gmail.com"). The colon makes the
        // boundary unambiguous and is invalid in any of the id formats we use.
        //
        // Provider buckets are intentionally named after the OAuth identity,
        // not the Source — one Google grant covers Gmail + Calendar, one
        // Microsoft grant covers Outlook + Calendar.

        static func googleAccess(_ id: String) -> String { "google.oauth.access:\(id)" }
        static func googleRefresh(_ id: String) -> String { "google.oauth.refresh:\(id)" }
        static func googleExpiry(_ id: String) -> String { "google.oauth.expiry:\(id)" }

        static func microsoftAccess(_ id: String) -> String { "microsoft.oauth.access:\(id)" }
        static func microsoftRefresh(_ id: String) -> String { "microsoft.oauth.refresh:\(id)" }
        static func microsoftExpiry(_ id: String) -> String { "microsoft.oauth.expiry:\(id)" }

        static func githubAccess(_ id: String) -> String { "github.oauth.access:\(id)" }
        static func githubPAT(_ id: String) -> String { "github.pat:\(id)" }

        static func slackAccess(_ id: String) -> String { "slack.oauth.access:\(id)" }
        static func slackClientID(_ id: String) -> String { "slack.client_id:\(id)" }
        static func slackClientSecret(_ id: String) -> String { "slack.client_secret:\(id)" }
        static func slackUserID(_ id: String) -> String { "slack.user_id:\(id)" }

        // Legacy unsuffixed keys, only read by KeychainMigration on first
        // launch after multi-account support landed. After migration these
        // entries are deleted from the keychain.
        static let legacyGmailAccess = "gmail.oauth.access"
        static let legacyGmailRefresh = "gmail.oauth.refresh"
        static let legacyGmailExpiry = "gmail.oauth.expiry"
        static let legacyOutlookAccess = "outlook.oauth.access"
        static let legacyOutlookRefresh = "outlook.oauth.refresh"
        static let legacyOutlookExpiry = "outlook.oauth.expiry"
        static let legacyGitHubAccess = "github.oauth.access"
        static let legacyGitHubPAT = "github.pat"
        static let legacySlackAccess = "slack.oauth.access"
        static let legacySlackClientID = "slack.client_id"
        static let legacySlackClientSecret = "slack.client_secret"
        static let legacySlackUserID = "slack.user_id"
        static let legacySlackTeamID = "slack.team_id"
    }
}
