import Foundation
import AppKit
import CryptoKit

/// Gmail via Google OAuth installed-app flow (loopback redirect + PKCE).
///
/// The user must provide their own OAuth 2.0 Client ID of type "Desktop app"
/// from Google Cloud Console. We don't bundle a default because:
///   - quotas would be shared across all users of the app
///   - Google's verification requirements apply per client
enum GoogleOAuth {
    static let authorizeURL = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    static let scopes = "https://www.googleapis.com/auth/gmail.readonly"

    struct Tokens: Codable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Int?
    }

    static func connect(clientID: String) async throws -> Tokens {
        let server = LoopbackOAuthServer()
        let port = try await server.start()
        defer { server.stop() }

        let redirect = "http://127.0.0.1:\(port)/"
        let verifier = randomURLSafe(32)
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
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirect,
        ]
        return try await postForm(tokenURL, form: form)
    }

    static func refreshTokens(clientID: String, refreshToken: String) async throws -> Tokens {
        let form = [
            "client_id": clientID,
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
        guard let clientID = Keychain.get(Keychain.Key.gmailClientID),
              let access = Keychain.get(Keychain.Key.gmailAccess) else { return nil }
        let expiryStr = Keychain.get(Keychain.Key.gmailExpiry)
        let expiry = expiryStr.flatMap { ISO8601DateFormatter().date(from: $0) } ?? .distantPast
        if Date() < expiry.addingTimeInterval(-60) { return access }
        guard let refresh = Keychain.get(Keychain.Key.gmailRefresh) else { return access }
        do {
            let t = try await refreshTokens(clientID: clientID, refreshToken: refresh)
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
        Keychain.get(Keychain.Key.gmailClientID) != nil &&
        Keychain.get(Keychain.Key.gmailRefresh) != nil
    }

    func fetch() async throws -> [RawItem] {
        guard let token = await GoogleOAuth.validAccessToken() else { return [] }

        // Unread + inbox + drop promotional buckets — cuts token volume a lot.
        let query = "is:unread in:inbox -category:promotions -category:social -category:updates"
        var listURL = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")!
        listURL.queryItems = [
            .init(name: "q", value: query),
            .init(name: "maxResults", value: "20"),
        ]
        var listReq = URLRequest(url: listURL.url!)
        listReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (listData, listResp) = try await URLSession.shared.data(for: listReq)
        guard let http = listResp as? HTTPURLResponse, http.statusCode == 200 else {
            throw SourceError(source: source, message: "list HTTP \((listResp as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        struct ListResp: Decodable {
            let messages: [Ref]?
            struct Ref: Decodable { let id: String }
        }
        let ids = (try JSONDecoder().decode(ListResp.self, from: listData).messages ?? []).map { $0.id }

        return try await withThrowingTaskGroup(of: RawItem?.self) { group in
            for id in ids {
                group.addTask { try await Self.fetchMetadata(id: id, token: token) }
            }
            var out: [RawItem] = []
            for try await item in group { if let item { out.append(item) } }
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
        let headers = Dictionary(uniqueKeysWithValues: (m.payload?.headers ?? []).map { ($0.name.lowercased(), $0.value) })
        let subject = headers["subject"] ?? "(no subject)"
        let from = headers["from"]
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
}
