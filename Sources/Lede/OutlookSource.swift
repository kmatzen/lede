import Foundation
import AppKit
import CryptoKit

/// Outlook via Microsoft Graph v1.0. OAuth 2.0 auth code + PKCE with loopback redirect.
///
/// Client ID embeds the Lede Azure AD app registration. It's a public
/// identifier — Microsoft's public-client flow uses PKCE, no client secret,
/// so nothing sensitive leaks. The app is registered as "Any Entra ID tenant
/// + personal Microsoft accounts" so tenant is `common` — Microsoft routes
/// each user through whichever provider matches their email. Enterprise
/// tenants with strict app-consent policies may need an admin to approve
/// Lede's scopes (Mail.Read, Calendars.Read, User.Read, offline_access)
/// before the user can complete the flow.
enum MicrosoftOAuth {
    static let clientID = "d45905df-daf4-4ee0-a2b9-a3f37ba177dd"
    static let tenant = "common"

    static let tokenHost = "https://login.microsoftonline.com"
    static let scopes = "offline_access Mail.Read Calendars.Read User.Read"

    private static var authorizeURL: URL {
        URL(string: "\(tokenHost)/\(tenant)/oauth2/v2.0/authorize")!
    }
    private static var tokenURL: URL {
        URL(string: "\(tokenHost)/\(tenant)/oauth2/v2.0/token")!
    }

    struct Tokens: Codable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Int?
    }

    struct Identity {
        let id: String          // Graph user id (immutable) — Account.id
        let label: String       // userPrincipalName / email — UI label
    }

    static func connect() async throws -> Tokens {
        let server = LoopbackOAuthServer()
        let port = try await server.start()
        defer { server.stop() }

        let redirect = "http://localhost:\(port)"
        let verifier = randomURLSafe(64)
        let challenge = s256(verifier)
        let state = randomURLSafe(16)

        var comps = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "response_mode", value: "query"),
            .init(name: "scope", value: scopes),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "prompt", value: "select_account"),
        ]
        NSWorkspace.shared.open(comps.url!)

        let cb = try await server.waitForCallback()
        if let e = cb.error { throw OAuthError.http(400, e) }
        guard let code = cb.code else { throw OAuthError.http(400, "no code") }
        guard cb.state == state else { throw OAuthError.stateMismatch }

        let form = [
            "client_id": clientID,
            "scope": scopes,
            "code": code,
            "redirect_uri": redirect,
            "grant_type": "authorization_code",
            "code_verifier": verifier,
        ]
        return try await postForm(tokenURL, form: form)
    }

    static func refresh(refreshToken: String) async throws -> Tokens {
        let form = [
            "client_id": clientID,
            "scope": scopes,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ]
        return try await postForm(tokenURL, form: form)
    }

    static func identity(accessToken: String) async throws -> Identity {
        var req = URLRequest(url: URL(string: "https://graph.microsoft.com/v1.0/me")!)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw OAuthError.http((resp as? HTTPURLResponse)?.statusCode ?? 0,
                                  String(data: data, encoding: .utf8) ?? "")
        }
        struct Me: Decodable {
            let id: String
            let userPrincipalName: String?
            let mail: String?
            let displayName: String?
        }
        let me = try JSONDecoder().decode(Me.self, from: data)
        let label = me.mail ?? me.userPrincipalName ?? me.displayName ?? me.id
        return Identity(id: me.id, label: label)
    }

    static func persist(_ t: Tokens, accountID: String) {
        Keychain.set(t.access_token, for: Keychain.Key.microsoftAccess(accountID))
        if let r = t.refresh_token {
            Keychain.set(r, for: Keychain.Key.microsoftRefresh(accountID))
        }
        let expiry = Date().addingTimeInterval(Double(t.expires_in ?? 3000))
        Keychain.set(ISO8601DateFormatter().string(from: expiry),
                     for: Keychain.Key.microsoftExpiry(accountID))
    }

    static func validAccessToken(accountID: String) async -> String? {
        guard let access = Keychain.get(Keychain.Key.microsoftAccess(accountID)) else { return nil }
        let expiryStr = Keychain.get(Keychain.Key.microsoftExpiry(accountID))
        let expiry = expiryStr.flatMap { ISO8601DateFormatter().date(from: $0) } ?? .distantPast
        if Date() < expiry.addingTimeInterval(-60) { return access }
        guard let r = Keychain.get(Keychain.Key.microsoftRefresh(accountID)) else { return access }
        do {
            let t = try await refresh(refreshToken: r)
            persist(t, accountID: accountID)
            return t.access_token
        } catch {
            return access
        }
    }

    static func signOut(accountID: String) {
        Keychain.delete(Keychain.Key.microsoftAccess(accountID))
        Keychain.delete(Keychain.Key.microsoftRefresh(accountID))
        Keychain.delete(Keychain.Key.microsoftExpiry(accountID))
    }

    /// Diagnostic for Graph 401s: logs the response body, the
    /// `WWW-Authenticate` header (which says "insufficient_scope" when
    /// admin consent is the issue), and the relevant JWT claims from the
    /// access token (scp / aud / tid). Useful for telling apart consent
    /// gates, audience mismatches, and Conditional Access blocks. Never
    /// logs the token itself.
    static func logGraphAuthFailure(endpoint: String,
                                    response: HTTPURLResponse,
                                    body: Data,
                                    accessToken: String) {
        let bodyStr = String(data: body, encoding: .utf8)?.prefix(800) ?? ""
        let wwwAuth = response.value(forHTTPHeaderField: "WWW-Authenticate") ?? "<none>"
        Log.error("Graph \(response.statusCode) on \(endpoint): \(bodyStr)")
        Log.error("  WWW-Authenticate: \(wwwAuth)")
        if let claims = jwtClaimsSummary(accessToken) {
            Log.error("  token claims: \(claims)")
        } else {
            Log.error("  token claims: <unparseable>")
        }
    }

    /// Decode the JWT payload (middle segment) and return a one-line summary
    /// of the diagnostic claims. Signature is not verified — local logging only.
    private static func jwtClaimsSummary(_ token: String) -> String? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let keys = ["scp", "roles", "aud", "tid", "appid", "iss", "ver"]
        return keys.compactMap { k -> String? in
            guard let v = json[k] else { return nil }
            return "\(k)=\(v)"
        }.joined(separator: " ")
    }

    // MARK: - helpers

    private static func postForm(_ url: URL, form: [String: String]) async throws -> Tokens {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "content-type")
        req.httpBody = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }
            .joined(separator: "&").data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw OAuthError.http((resp as? HTTPURLResponse)?.statusCode ?? 0,
                                  String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(Tokens.self, from: data)
    }

    private static func randomURLSafe(_ bytes: Int) -> String {
        var b = Data(count: bytes)
        _ = b.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        return b.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func s256(_ verifier: String) -> String {
        let h = SHA256.hash(data: Data(verifier.utf8))
        return Data(h).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

struct OutlookSource: NotificationSource {
    let account: Account
    let source: Source = .outlook

    var isConfigured: Bool {
        Keychain.get(Keychain.Key.microsoftRefresh(account.id)) != nil
    }

    func fetch() async throws -> FetchResult {
        guard let token = await MicrosoftOAuth.validAccessToken(accountID: account.id) else {
            return FetchResult(items: [])
        }

        struct ListResp: Decodable {
            let value: [Msg]
            let nextLink: String?
            enum CodingKeys: String, CodingKey {
                case value
                case nextLink = "@odata.nextLink"
            }
            struct Msg: Decodable {
                let id: String
                let subject: String?
                let bodyPreview: String?
                let receivedDateTime: Date
                let webLink: String?
                let from: From?
                struct From: Decodable {
                    let emailAddress: EmailAddress?
                    struct EmailAddress: Decodable { let name: String?; let address: String? }
                }
            }
        }

        // Enterprise Outlook users heavily rely on Server-side Rules to
        // route mail to subfolders (alerting, compliance, ticket queues,
        // project folders) — those messages skip the Inbox entirely. We
        // used to query `/me/mailFolders/Inbox/messages` so subfolder
        // unreads were invisible.
        //
        // Switch to `/me/messages` (account-wide), then exclude messages
        // whose parent is a system folder we never want to surface
        // (Junk, Deleted, Sent, Drafts, Outbox, sync-issues, etc.).
        // The exclusion is built from a one-time `/me/mailFolders` lookup
        // that returns each folder's `wellKnownName`; if that lookup
        // fails the worst case is we surface noise from those folders
        // until the next refresh succeeds, not a fetch failure.
        let excludedFolderIDs = await Self.excludedParentFolderIDs(token: token)
        let filter = Self.buildUnreadFilter(excludingParentFolderIDs: excludedFolderIDs)

        // First page is built locally; subsequent pages use Graph's
        // `@odata.nextLink` URL verbatim — Microsoft warns against
        // reconstructing it (skiptokens are opaque). Walk until the
        // cap is hit or there's no next link.
        let firstURL: URL = {
            var comps = URLComponents(string: "https://graph.microsoft.com/v1.0/me/messages")!
            comps.queryItems = [
                .init(name: "$filter", value: filter),
                .init(name: "$select", value: "id,subject,from,bodyPreview,receivedDateTime,webLink"),
                .init(name: "$top", value: "50"),
                .init(name: "$orderby", value: "receivedDateTime desc"),
            ]
            return comps.url!
        }()

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var msgs: [ListResp.Msg] = []
        var omitted = 0
        var nextURL: URL? = firstURL
        let cap = SourcePagination.softCap

        while let url = nextURL {
            var req = URLRequest(url: url)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                if let http = resp as? HTTPURLResponse, http.statusCode == 401 || http.statusCode == 403 {
                    MicrosoftOAuth.logGraphAuthFailure(endpoint: "/me/messages",
                                                       response: http, body: data, accessToken: token)
                }
                throw SourceError(source: source,
                                  message: "HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0) \(String(data: data, encoding: .utf8)?.prefix(200) ?? "")")
            }
            let parsed = try decoder.decode(ListResp.self, from: data)
            msgs.append(contentsOf: parsed.value)

            if msgs.count >= cap {
                if msgs.count > cap {
                    omitted = max(omitted, msgs.count - cap)
                    msgs = Array(msgs.prefix(cap))
                }
                if (parsed.nextLink ?? "").isEmpty == false {
                    omitted = max(omitted, 1)
                }
                nextURL = nil
            } else {
                nextURL = parsed.nextLink.flatMap { URL(string: $0) }
            }
        }

        let acct = account
        let items = msgs.map { m -> RawItem in
            let senderName = m.from?.emailAddress?.name
            let senderAddr = m.from?.emailAddress?.address
            let sender: String? = {
                if let n = senderName, !n.isEmpty { return "\(n) <\(senderAddr ?? "")>" }
                return senderAddr
            }()
            return RawItem(
                id: m.id,
                source: .outlook,
                accountID: acct.id,
                accountLabel: acct.label,
                title: m.subject ?? "(no subject)",
                sender: sender,
                snippet: String((m.bodyPreview ?? "").prefix(500)),
                url: m.webLink.flatMap { URL(string: $0) },
                receivedAt: m.receivedDateTime,
                isUnread: true
            )
        }
        Log.info("outlook[\(acct.label)]: returned \(items.count) message(s)\(omitted > 0 ? " (cap hit, ≥\(omitted) more)" : "")")
        return FetchResult(items: items, omitted: omitted)
    }

    /// Compose the Graph `$filter` clause for the messages query: always
    /// `isRead eq false`, plus a `parentFolderId ne 'X'` for each
    /// excluded folder ID. Graph filter literals are single-quoted; the
    /// folder IDs Graph returns are base64-style (no quotes inside) so
    /// we don't need an escape pass.
    static func buildUnreadFilter(excludingParentFolderIDs ids: [String]) -> String {
        var parts = ["isRead eq false"]
        for id in ids {
            parts.append("parentFolderId ne '\(id)'")
        }
        return parts.joined(separator: " and ")
    }

    /// `wellKnownName` values whose unread mail we should never surface
    /// — system folders for sent/draft/junk/deleted/sync-issues etc. We
    /// keep `inbox`, `archive` (auto-archive may move read mail there
    /// but the user might intentionally archive an unread item), and
    /// any custom user folder (those have a nil `wellKnownName`).
    static let excludedWellKnownFolderNames: Set<String> = [
        "sentitems", "drafts", "junkemail", "deleteditems", "outbox",
        "conflicts", "conversationhistory", "localfailures",
        "recoverableitemsdeletions", "scheduled", "searchfolders",
        "serverfailures", "syncissues", "tasks", "clutter",
    ]

    /// One Graph call per fetch to discover the folder IDs whose
    /// `wellKnownName` is in the exclusion set, so the per-message
    /// `$filter` can drop their contents server-side. Returns an empty
    /// array on any failure — the messages query still runs, just
    /// without the exclusion (degraded but not broken).
    static func excludedParentFolderIDs(token: String) async -> [String] {
        var comps = URLComponents(string: "https://graph.microsoft.com/v1.0/me/mailFolders")!
        comps.queryItems = [
            .init(name: "$select", value: "id,wellKnownName"),
            .init(name: "$top", value: "100"),
        ]
        guard let url = comps.url else { return [] }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            Log.warn("outlook: mailFolders lookup for exclusion list failed; proceeding without folder filter")
            return []
        }
        struct Resp: Decodable {
            let value: [Folder]?
            struct Folder: Decodable {
                let id: String
                let wellKnownName: String?
            }
        }
        guard let parsed = try? JSONDecoder().decode(Resp.self, from: data) else { return [] }
        return (parsed.value ?? []).compactMap { f -> String? in
            guard let name = f.wellKnownName?.lowercased() else { return nil }
            return excludedWellKnownFolderNames.contains(name) ? f.id : nil
        }
    }
}
