import Foundation
import AppKit
import CryptoKit

/// Gmail via Google OAuth installed-app flow (loopback redirect + PKCE).
///
/// Client ID + Secret are embedded. Per Google's own native-app OAuth guidance
/// (https://developers.google.com/identity/protocols/oauth2/native-app#clientid),
/// client secrets for Desktop-app OAuth clients are "not actually secret" —
/// they're baked into binaries (gcloud, Chrome, ytdl, etc.). Safe to embed.
///
/// Scope is `gmail.metadata` (headers + snippet only, no message bodies). That
/// keeps us in Google's "Sensitive" tier (brand verification) rather than
/// "Restricted" (requires CASA security assessment). Enough for triage.
enum GoogleOAuth {
    static let clientID = "260531225051-k2hp892mjupscpqunacpp4ramnd8v46d.apps.googleusercontent.com"
    static let clientSecret = "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"

    static let authorizeURL = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    static let scopes = "https://www.googleapis.com/auth/gmail.metadata https://www.googleapis.com/auth/calendar.readonly https://www.googleapis.com/auth/userinfo.email"

    struct Tokens: Codable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Int?
    }

    struct Identity {
        let id: String          // email — used as Account.id
        let label: String       // email — shown in UI
    }

    static func connect() async throws -> Tokens {
        let server = LoopbackOAuthServer()
        let port = try await server.start()
        defer { server.stop() }

        let redirect = "http://127.0.0.1:\(port)/"
        let verifier = randomURLSafe(64)
        let challenge = s256(verifier)
        let state = randomURLSafe(16)

        var comps = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: scopes),
            .init(name: "access_type", value: "offline"),
            // `consent` (not `select_account`) so a second connect on the same
            // browser profile re-issues a refresh_token, not just an access one.
            .init(name: "prompt", value: "consent select_account"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
        ]
        NSWorkspace.shared.open(comps.url!)

        let cb = try await server.waitForCallback()
        if let e = cb.error { throw OAuthError.http(400, e) }
        guard let code = cb.code else { throw OAuthError.http(400, "no code") }
        guard cb.state == state else { throw OAuthError.stateMismatch }

        let form = [
            "client_id": clientID,
            "client_secret": clientSecret,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirect,
        ]
        return try await postForm(tokenURL, form: form)
    }

    static func refreshTokens(refreshToken: String) async throws -> Tokens {
        let form = [
            "client_id": clientID,
            "client_secret": clientSecret,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ]
        return try await postForm(tokenURL, form: form)
    }

    static func identity(accessToken: String) async throws -> Identity {
        var req = URLRequest(url: URL(string: "https://www.googleapis.com/oauth2/v3/userinfo")!)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw OAuthError.http((resp as? HTTPURLResponse)?.statusCode ?? 0,
                                  String(data: data, encoding: .utf8) ?? "")
        }
        struct UserInfo: Decodable { let email: String? }
        let info = try JSONDecoder().decode(UserInfo.self, from: data)
        guard let email = info.email, !email.isEmpty else {
            throw OAuthError.http(400, "userinfo missing email")
        }
        return Identity(id: email, label: email)
    }

    static func persist(_ t: Tokens, accountID: String) {
        Keychain.set(t.access_token, for: Keychain.Key.googleAccess(accountID))
        if let r = t.refresh_token {
            Keychain.set(r, for: Keychain.Key.googleRefresh(accountID))
        }
        let expiry = Date().addingTimeInterval(Double(t.expires_in ?? 3000))
        Keychain.set(ISO8601DateFormatter().string(from: expiry),
                     for: Keychain.Key.googleExpiry(accountID))
    }

    static func validAccessToken(accountID: String) async -> String? {
        guard let access = Keychain.get(Keychain.Key.googleAccess(accountID)) else { return nil }
        let expiryStr = Keychain.get(Keychain.Key.googleExpiry(accountID))
        let expiry = expiryStr.flatMap { ISO8601DateFormatter().date(from: $0) } ?? .distantPast
        if Date() < expiry.addingTimeInterval(-60) { return access }
        guard let refresh = Keychain.get(Keychain.Key.googleRefresh(accountID)) else { return access }
        do {
            let t = try await refreshTokens(refreshToken: refresh)
            persist(t, accountID: accountID)
            return t.access_token
        } catch {
            return access
        }
    }

    static func signOut(accountID: String) {
        Keychain.delete(Keychain.Key.googleAccess(accountID))
        Keychain.delete(Keychain.Key.googleRefresh(accountID))
        Keychain.delete(Keychain.Key.googleExpiry(accountID))
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
            throw OAuthError.http((resp as? HTTPURLResponse)?.statusCode ?? 0, String(data: data, encoding: .utf8) ?? "")
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

// MARK: - Source implementation

struct GmailSource: NotificationSource {
    let account: Account
    let source: Source = .gmail

    var isConfigured: Bool {
        Keychain.get(Keychain.Key.googleRefresh(account.id)) != nil
    }

    /// System labels that disqualify a message from the digest. SPAM/TRASH
    /// are obvious; SENT/DRAFT/CHAT keep the user's own outgoing mail and
    /// legacy Hangouts scrollback out — relevant now that we query UNREAD
    /// alone (no INBOX gate), since drafts especially can carry UNREAD.
    static let skipLabels: Set<String> = ["SPAM", "TRASH", "SENT", "DRAFT", "CHAT"]

    func fetch() async throws -> FetchResult {
        guard let token = await GoogleOAuth.validAccessToken(accountID: account.id) else {
            return FetchResult(items: [])
        }

        // `gmail.metadata` scope forbids the `q` search param (Google: "query
        // text could expose body content"). We filter by labelIds and finish
        // any remaining filtering client-side once we have each message's
        // labelIds.
        //
        // Use UNREAD alone — *not* INBOX ∧ UNREAD. Power users routinely set
        // up filters that auto-archive (skip the inbox) and apply a custom
        // label: CI alerts → Label/CI, security alerts → Label/Security,
        // PagerDuty → Label/Oncall, calendar invites → Label/Calendar.
        // Filtering by INBOX dropped exactly those — the highest-signal
        // automated mail the user has already invested in triaging. Volume
        // risk (large UNREAD backlog from old auto-archived mail) is
        // bounded by the per-source soft cap and by manual-Claude mode
        // (default on) which doesn't call Claude until the user asks.
        //
        // System labels we DO drop client-side below: SPAM/TRASH (junk by
        // definition), SENT/DRAFT (the user's own outgoing mail —
        // shouldn't appear in their notifications digest), and the
        // legacy CHAT label (defunct Hangouts).
        //
        // Walk `nextPageToken` until we hit the soft cap or the cursor is
        // exhausted. `maxResults` per page is 100 (Gmail's default ceiling
        // for messages.list); the soft cap then bounds total work without
        // making each round-trip wastefully small.
        struct ListResp: Decodable {
            let messages: [Ref]?
            let nextPageToken: String?
            struct Ref: Decodable { let id: String }
        }
        var ids: [String] = []
        var pageToken: String? = nil
        var omitted = 0
        let cap = SourcePagination.softCap
        repeat {
            var listURL = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")!
            var items: [URLQueryItem] = [
                .init(name: "labelIds", value: "UNREAD"),
                .init(name: "maxResults", value: "100"),
            ]
            if let t = pageToken { items.append(.init(name: "pageToken", value: t)) }
            listURL.queryItems = items
            var listReq = URLRequest(url: listURL.url!)
            listReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (listData, listResp) = try await URLSession.shared.data(for: listReq)
            guard let http = listResp as? HTTPURLResponse, http.statusCode == 200 else {
                let body = String(data: listData, encoding: .utf8) ?? ""
                throw SourceError(
                    source: source,
                    message: "list HTTP \((listResp as? HTTPURLResponse)?.statusCode ?? 0) — \(body.prefix(400))"
                )
            }
            let parsed = try JSONDecoder().decode(ListResp.self, from: listData)
            for ref in parsed.messages ?? [] { ids.append(ref.id) }
            // Soft cap: if we already have enough and there's still more,
            // record a "≥1 more exists" hint and stop.
            if ids.count >= cap {
                if (parsed.nextPageToken ?? "").isEmpty == false || ids.count > cap {
                    omitted = max(omitted, max(1, ids.count - cap))
                }
                if ids.count > cap { ids = Array(ids.prefix(cap)) }
                pageToken = nil
            } else {
                let next = parsed.nextPageToken ?? ""
                pageToken = next.isEmpty ? nil : next
            }
        } while pageToken != nil
        Log.info("gmail[\(account.label)]: list returned \(ids.count) message id(s)\(omitted > 0 ? " (cap hit, ≥\(omitted) more)" : "")")

        let acct = account
        // Gmail returns HTTP 429 "Too many concurrent requests for user." well
        // before any per-second quota kicks in. Cap in-flight gets at 8.
        let maxInFlight = 8
        let items = await withTaskGroup(of: MetadataResult.self) { group -> [RawItem] in
            var out: [RawItem] = []
            var filtered = 0
            var errored = 0
            var next = 0
            for id in ids.prefix(maxInFlight) {
                group.addTask { await Self.fetchMetadata(id: id, token: token, account: acct) }
                next += 1
            }
            while let result = await group.next() {
                if next < ids.count {
                    let id = ids[next]
                    group.addTask { await Self.fetchMetadata(id: id, token: token, account: acct) }
                    next += 1
                }
                switch result {
                case .kept(let item): out.append(item)
                case .filtered: filtered += 1
                case .errored: errored += 1
                }
            }
            Log.info("gmail[\(acct.label)]: kept \(out.count), filtered \(filtered), errored \(errored)")
            return out
        }
        return FetchResult(items: items, omitted: omitted)
    }

    private enum MetadataResult { case kept(RawItem), filtered, errored }

    private static func fetchMetadata(id: String, token: String, account: Account) async -> MetadataResult {
        var comps = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(id)")!
        comps.queryItems = [
            .init(name: "format", value: "metadata"),
            .init(name: "metadataHeaders", value: "From"),
            .init(name: "metadataHeaders", value: "Subject"),
            .init(name: "metadataHeaders", value: "Date"),
        ]
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let data: Data
        do {
            let (d, resp) = try await URLSession.shared.data(for: req)
            // 404 happens when a message is deleted between list and get; 429
            // when we exceed per-user quota. Drop the offender, don't fail the
            // whole batch — but log the body so the reason is visible.
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                let body = String(data: d, encoding: .utf8)?.prefix(300) ?? ""
                Log.warn("gmail[\(account.label)]: get \(id) HTTP \(http.statusCode) — \(body)")
                return .errored
            }
            data = d
        } catch {
            Log.warn("gmail[\(account.label)]: get \(id) network error — \(error.localizedDescription)")
            return .errored
        }
        struct Msg: Decodable {
            let id: String
            let snippet: String?
            let internalDate: String?
            let labelIds: [String]?
            let payload: Payload?
            struct Payload: Decodable {
                let headers: [Header]?
                struct Header: Decodable { let name: String; let value: String }
            }
        }
        let m: Msg
        do {
            m = try JSONDecoder().decode(Msg.self, from: data)
        } catch {
            // Name the missing/mistyped field instead of the localized "data
            // couldn't be read" — that's what made the original failure opaque.
            let detail = describeDecodingError(error)
            let body = String(data: data, encoding: .utf8)?.prefix(300) ?? ""
            Log.warn("gmail[\(account.label)]: get \(id) decode failed — \(detail) — body: \(body)")
            return .errored
        }

        // Drop only what Gmail+the user have explicitly demoted. We used to
        // also filter CATEGORY_PROMOTIONS / SOCIAL / UPDATES wholesale, but
        // Gmail mis-categorizes constantly — UPDATES in particular catches
        // order confirmations, billing notices, security alerts, password
        // resets, and calendar invites. Letting them through and trusting
        // the triage prompt to score promotional noise low loses fewer real
        // notifications.
        //
        // SENT / DRAFT / CHAT are added because we now query by UNREAD only
        // (no INBOX gate), and those system labels can carry UNREAD in
        // edge cases (drafts especially) — the user doesn't want their
        // own outgoing mail or chat scrollback surfaced as a notification.
        let labels = Set(m.labelIds ?? [])
        if !labels.isDisjoint(with: skipLabels) { return .filtered }

        let headers = Dictionary(uniqueKeysWithValues: (m.payload?.headers ?? []).map { ($0.name.lowercased(), $0.value) })
        let subject = headers["subject"] ?? "(no subject)"
        let from = parseFromHeader(headers["from"])
        let received: Date = {
            if let ms = m.internalDate, let n = Double(ms) { return Date(timeIntervalSince1970: n / 1000) }
            return Date()
        }()
        let url = URL(string: "https://mail.google.com/mail/u/0/#inbox/\(m.id)")
        return .kept(RawItem(
            id: m.id,
            source: .gmail,
            accountID: account.id,
            accountLabel: account.label,
            title: subject,
            sender: from,
            snippet: String((m.snippet ?? "").prefix(500)),
            url: url,
            receivedAt: received,
            isUnread: (m.labelIds ?? []).contains("UNREAD")
        ))
    }

    private static func describeDecodingError(_ error: Error) -> String {
        guard let e = error as? DecodingError else { return error.localizedDescription }
        func path(_ keys: [CodingKey]) -> String {
            keys.map(\.stringValue).joined(separator: ".")
        }
        switch e {
        case .keyNotFound(let k, let ctx):
            return "keyNotFound \(k.stringValue) at \(path(ctx.codingPath))"
        case .valueNotFound(let t, let ctx):
            return "valueNotFound \(t) at \(path(ctx.codingPath))"
        case .typeMismatch(let t, let ctx):
            return "typeMismatch \(t) at \(path(ctx.codingPath))"
        case .dataCorrupted(let ctx):
            return "dataCorrupted at \(path(ctx.codingPath)): \(ctx.debugDescription)"
        @unknown default:
            return "\(e)"
        }
    }

    /// RFC 2822 From headers are typically `"Display Name" <addr@host>` or just
    /// `addr@host`. For triage we prefer the display name (more informative than
    /// an email address); fall back to the address.
    static func parseFromHeader(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        // Strip surrounding quotes, RFC 2047 encoded-words we can't decode here.
        if let lt = raw.firstIndex(of: "<") {
            let namePart = raw[..<lt]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if !namePart.isEmpty { return namePart }
            // `<addr>` only
            if let gt = raw.firstIndex(of: ">") {
                return String(raw[raw.index(after: lt)..<gt])
            }
        }
        return raw
    }
}
