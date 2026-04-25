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
        static let anthropicAPIKey = "anthropic.api_key"
        static let anthropicOAuthAccess = "anthropic.oauth.access"
        static let anthropicOAuthRefresh = "anthropic.oauth.refresh"
        static let anthropicOAuthExpiry = "anthropic.oauth.expiry"
        static let githubPAT = "github.pat"
        static let githubAccess = "github.oauth.access"
        static let gmailAccess = "gmail.oauth.access"
        static let gmailRefresh = "gmail.oauth.refresh"
        static let gmailExpiry = "gmail.oauth.expiry"
        static let slackClientID = "slack.client_id"
        static let slackClientSecret = "slack.client_secret"
        static let slackAccess = "slack.oauth.access"
        static let slackUserID = "slack.user_id"
        static let slackTeamID = "slack.team_id"
        static let outlookAccess = "outlook.oauth.access"
        static let outlookRefresh = "outlook.oauth.refresh"
        static let outlookExpiry = "outlook.oauth.expiry"
    }
}
