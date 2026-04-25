import Foundation
import Security

/// Two migrations live here:
///
/// 1. **Service rename** — `com.claudenotif.app` → `com.lede.app`. One-shot
///    keychain copy, run sync at launch.
///
/// 2. **Single → multi-account** — legacy unsuffixed keys
///    (`gmail.oauth.access`, `outlook.oauth.access`, etc.) get rewritten under
///    per-account keys after we discover each account's identity. Async because
///    identity discovery requires a network round-trip per provider.
enum KeychainMigration {
    private static let serviceMigratedFlag = "lede.keychain.migrated.v1"
    private static let accountsMigratedFlag = "lede.accounts.migrated.v1"

    static func runIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: serviceMigratedFlag) else { return }

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
        defaults.set(true, forKey: serviceMigratedFlag)
    }

    /// Convert any single-account keychain credentials into Account records +
    /// per-account keys. Idempotent — runs at most once per install.
    static func migrateAccountsIfNeeded(storage: Storage) async {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: accountsMigratedFlag) { return }

        // If the user already has accounts on disk, the migration was either
        // run before this flag existed, or they're a fresh install. Either way
        // there's nothing to do — set the flag and bail.
        let existing = await storage.allAccounts()
        if !existing.isEmpty {
            defaults.set(true, forKey: accountsMigratedFlag)
            return
        }

        await migrateGoogle(storage: storage)
        await migrateMicrosoft(storage: storage)
        await migrateGitHub(storage: storage)
        await migrateSlack(storage: storage)

        defaults.set(true, forKey: accountsMigratedFlag)
    }

    // MARK: - Per-provider migrations

    private static func migrateGoogle(storage: Storage) async {
        guard let access = Keychain.get(Keychain.Key.legacyGmailAccess),
              let refresh = Keychain.get(Keychain.Key.legacyGmailRefresh) else { return }

        // Refresh the access token if it's stale before calling userinfo.
        var workingToken = access
        do {
            let t = try await GoogleOAuth.refreshTokens(refreshToken: refresh)
            workingToken = t.access_token
        } catch {
            Log.warn("account migration: google refresh failed, trying existing access token — \(error.localizedDescription)")
        }

        let identity: GoogleOAuth.Identity
        do {
            identity = try await GoogleOAuth.identity(accessToken: workingToken)
        } catch {
            Log.warn("account migration: google identity fetch failed — \(error.localizedDescription)")
            return
        }

        Keychain.set(workingToken, for: Keychain.Key.googleAccess(identity.id))
        Keychain.set(refresh, for: Keychain.Key.googleRefresh(identity.id))
        if let expiry = Keychain.get(Keychain.Key.legacyGmailExpiry) {
            Keychain.set(expiry, for: Keychain.Key.googleExpiry(identity.id))
        }

        await storage.upsertAccount(Account(
            provider: .google, id: identity.id, label: identity.label, connectedAt: Date()
        ))

        Keychain.delete(Keychain.Key.legacyGmailAccess)
        Keychain.delete(Keychain.Key.legacyGmailRefresh)
        Keychain.delete(Keychain.Key.legacyGmailExpiry)

        Log.info("account migration: imported Google account \(identity.label)")
    }

    private static func migrateMicrosoft(storage: Storage) async {
        guard let access = Keychain.get(Keychain.Key.legacyOutlookAccess),
              let refresh = Keychain.get(Keychain.Key.legacyOutlookRefresh) else { return }

        var workingToken = access
        do {
            let t = try await MicrosoftOAuth.refresh(refreshToken: refresh)
            workingToken = t.access_token
        } catch {
            Log.warn("account migration: microsoft refresh failed, trying existing access token — \(error.localizedDescription)")
        }

        let identity: MicrosoftOAuth.Identity
        do {
            identity = try await MicrosoftOAuth.identity(accessToken: workingToken)
        } catch {
            Log.warn("account migration: microsoft identity fetch failed — \(error.localizedDescription)")
            return
        }

        Keychain.set(workingToken, for: Keychain.Key.microsoftAccess(identity.id))
        Keychain.set(refresh, for: Keychain.Key.microsoftRefresh(identity.id))
        if let expiry = Keychain.get(Keychain.Key.legacyOutlookExpiry) {
            Keychain.set(expiry, for: Keychain.Key.microsoftExpiry(identity.id))
        }

        await storage.upsertAccount(Account(
            provider: .microsoft, id: identity.id, label: identity.label, connectedAt: Date()
        ))

        Keychain.delete(Keychain.Key.legacyOutlookAccess)
        Keychain.delete(Keychain.Key.legacyOutlookRefresh)
        Keychain.delete(Keychain.Key.legacyOutlookExpiry)

        Log.info("account migration: imported Microsoft account \(identity.label)")
    }

    private static func migrateGitHub(storage: Storage) async {
        let oauthToken = Keychain.get(Keychain.Key.legacyGitHubAccess)
        let pat = Keychain.get(Keychain.Key.legacyGitHubPAT)
        guard let token = oauthToken ?? pat else { return }

        let identity: GitHubOAuth.Identity
        do {
            identity = try await GitHubOAuth.identity(token: token)
        } catch {
            Log.warn("account migration: github identity fetch failed — \(error.localizedDescription)")
            return
        }

        if oauthToken != nil {
            GitHubOAuth.persistOAuth(token: token, accountID: identity.id)
        } else {
            GitHubOAuth.persistPAT(token: token, accountID: identity.id)
        }

        await storage.upsertAccount(Account(
            provider: .github, id: identity.id, label: identity.label, connectedAt: Date()
        ))

        Keychain.delete(Keychain.Key.legacyGitHubAccess)
        Keychain.delete(Keychain.Key.legacyGitHubPAT)

        Log.info("account migration: imported GitHub account \(identity.label)")
    }

    private static func migrateSlack(storage: Storage) async {
        guard let token = Keychain.get(Keychain.Key.legacySlackAccess),
              let teamID = Keychain.get(Keychain.Key.legacySlackTeamID) else { return }
        let userID = Keychain.get(Keychain.Key.legacySlackUserID)
        let clientID = Keychain.get(Keychain.Key.legacySlackClientID) ?? ""
        let clientSecret = Keychain.get(Keychain.Key.legacySlackClientSecret) ?? ""

        // Try to fetch the team name. Falls back to team_id as the label.
        let label = await fetchSlackTeamName(token: token) ?? teamID

        Keychain.set(token, for: Keychain.Key.slackAccess(teamID))
        if !clientID.isEmpty { Keychain.set(clientID, for: Keychain.Key.slackClientID(teamID)) }
        if !clientSecret.isEmpty { Keychain.set(clientSecret, for: Keychain.Key.slackClientSecret(teamID)) }
        if let u = userID { Keychain.set(u, for: Keychain.Key.slackUserID(teamID)) }

        await storage.upsertAccount(Account(
            provider: .slack, id: teamID, label: label, connectedAt: Date()
        ))

        Keychain.delete(Keychain.Key.legacySlackAccess)
        Keychain.delete(Keychain.Key.legacySlackUserID)
        Keychain.delete(Keychain.Key.legacySlackTeamID)
        Keychain.delete(Keychain.Key.legacySlackClientID)
        Keychain.delete(Keychain.Key.legacySlackClientSecret)

        Log.info("account migration: imported Slack workspace \(label)")
    }

    private static func fetchSlackTeamName(token: String) async -> String? {
        var req = URLRequest(url: URL(string: "https://slack.com/api/team.info")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return nil }
        struct Resp: Decodable {
            let ok: Bool
            let team: Team?
            struct Team: Decodable { let name: String? }
        }
        guard let parsed = try? JSONDecoder().decode(Resp.self, from: data),
              parsed.ok, let name = parsed.team?.name, !name.isEmpty else { return nil }
        return name
    }
}
