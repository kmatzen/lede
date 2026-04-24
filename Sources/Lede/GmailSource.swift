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
    static let scopes = "https://www.googleapis.com/auth/gmail.metadata"

    struct Tokens: Codable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Int?
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
            .init(name: "prompt", value: "consent"),
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

    static func persist(_ t: Tokens) {
        Keychain.set(t.access_token, for: Keychain.Key.gmailAccess)
        if let r = t.refresh_token {
            Keychain.set(r, for: Keychain.Key.gmailRefresh)
        }
        let expiry = Date().addingTimeInterval(Double(t.expires_in ?? 3000))
        Keychain.set(ISO8601DateFormatter().string(from: expiry), for: Keychain.Key.gmailExpiry)
    }

    static func validAccessToken() async -> String? {
        guard let access = Keychain.get(Keychain.Key.gmailAccess) else { return nil }
        let expiryStr = Keychain.get(Keychain.Key.gmailExpiry)
        let expiry = expiryStr.flatMap { ISO8601DateFormatter().date(from: $0) } ?? .distantPast
        if Date() < expiry.addingTimeInterval(-60) { return access }
        guard let refresh = Keychain.get(Keychain.Key.gmailRefresh) else { return access }
        do {
            let t = try await refreshTokens(refreshToken: refresh)
            persist(t)
            return t.access_token
        } catch {
            return access
        }
    }

    static func signOut() {
        Keychain.delete(Keychain.Key.gmailAccess)
        Keychain.delete(Keychain.Key.gmailRefresh)
        Keychain.delete(Keychain.Key.gmailExpiry)
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
    let source: Source = .gmail

    var isConfigured: Bool {
        Keychain.get(Keychain.Key.gmailRefresh) != nil
    }

    func fetch() async throws -> [RawItem] {
        guard let token = await GoogleOAuth.validAccessToken() else { return [] }

        // `gmail.metadata` scope forbids the `q` search param (Google: "query
        // text could expose body content"). So we filter by labelIds here —
        // INBOX ∧ UNREAD — and drop the category-labeled stuff client-side
        // once we have each message's labelIds.
        var listURL = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")!
        listURL.queryItems = [
            .init(name: "labelIds", value: "INBOX"),
            .init(name: "labelIds", value: "UNREAD"),
            .init(name: "maxResults", value: "40"),
        ]
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
        struct ListResp: Decodable {
            let messages: [Ref]?
            struct Ref: Decodable { let id: String }
        }
        let ids = (try JSONDecoder().decode(ListResp.self, from: listData).messages ?? []).map { $0.id }
        Log.info("gmail: list returned \(ids.count) message id(s)")

        return try await withThrowingTaskGroup(of: RawItem?.self) { group in
            for id in ids {
                group.addTask { try await Self.fetchMetadata(id: id, token: token) }
            }
            var out: [RawItem] = []
            var skipped = 0
            for try await item in group {
                if let item { out.append(item) } else { skipped += 1 }
            }
            Log.info("gmail: kept \(out.count) item(s), dropped \(skipped) by client-side filter")
            return out
        }
    }

    private static func fetchMetadata(id: String, token: String) async throws -> RawItem? {
        var comps = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(id)")!
        comps.queryItems = [
            .init(name: "format", value: "metadata"),
            .init(name: "metadataHeaders", value: "From"),
            .init(name: "metadataHeaders", value: "Subject"),
            .init(name: "metadataHeaders", value: "Date"),
        ]
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: req)
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
        let m = try JSONDecoder().decode(Msg.self, from: data)

        // Filter out promotional / social / update-bucket mail here, since the
        // metadata scope doesn't let us express this in the list query.
        let skipLabels: Set<String> = ["CATEGORY_PROMOTIONS", "CATEGORY_SOCIAL", "CATEGORY_UPDATES", "SPAM", "TRASH"]
        if !Set(m.labelIds ?? []).isDisjoint(with: skipLabels) { return nil }

        let headers = Dictionary(uniqueKeysWithValues: (m.payload?.headers ?? []).map { ($0.name.lowercased(), $0.value) })
        let subject = headers["subject"] ?? "(no subject)"
        let from = parseFromHeader(headers["from"])
        let received: Date = {
            if let ms = m.internalDate, let n = Double(ms) { return Date(timeIntervalSince1970: n / 1000) }
            return Date()
        }()
        let url = URL(string: "https://mail.google.com/mail/u/0/#inbox/\(m.id)")
        return RawItem(
            id: m.id,
            source: .gmail,
            title: subject,
            sender: from,
            snippet: String((m.snippet ?? "").prefix(500)),
            url: url,
            receivedAt: received,
            isUnread: (m.labelIds ?? []).contains("UNREAD")
        )
    }

    /// RFC 2822 From headers are typically `"Display Name" <addr@host>` or just
    /// `addr@host`. For triage we prefer the display name (more informative than
    /// an email address); fall back to the address.
    private static func parseFromHeader(_ raw: String?) -> String? {
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
