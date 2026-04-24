import Foundation
import AppKit
import CryptoKit

/// Outlook via Microsoft Graph v1.0. OAuth 2.0 auth code + PKCE with loopback redirect.
///
/// Client ID embeds the Lede Azure AD app registration. It's a public
/// identifier — Microsoft's public-client flow uses PKCE, no client secret,
/// so nothing sensitive leaks. The app is registered as "Personal Microsoft
/// accounts only" so tenant is hardcoded to `consumers`.
enum MicrosoftOAuth {
    static let clientID = "d45905df-daf4-4ee0-a2b9-a3f37ba177dd"
    static let tenant = "consumers"

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

    static func persist(_ t: Tokens) {
        Keychain.set(t.access_token, for: Keychain.Key.outlookAccess)
        if let r = t.refresh_token {
            Keychain.set(r, for: Keychain.Key.outlookRefresh)
        }
        let expiry = Date().addingTimeInterval(Double(t.expires_in ?? 3000))
        Keychain.set(ISO8601DateFormatter().string(from: expiry), for: Keychain.Key.outlookExpiry)
    }

    static func validAccessToken() async -> String? {
        guard let access = Keychain.get(Keychain.Key.outlookAccess) else { return nil }
        let expiryStr = Keychain.get(Keychain.Key.outlookExpiry)
        let expiry = expiryStr.flatMap { ISO8601DateFormatter().date(from: $0) } ?? .distantPast
        if Date() < expiry.addingTimeInterval(-60) { return access }
        guard let r = Keychain.get(Keychain.Key.outlookRefresh) else { return access }
        do {
            let t = try await refresh(refreshToken: r)
            persist(t)
            return t.access_token
        } catch {
            return access
        }
    }

    static func signOut() {
        Keychain.delete(Keychain.Key.outlookAccess)
        Keychain.delete(Keychain.Key.outlookRefresh)
        Keychain.delete(Keychain.Key.outlookExpiry)
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
    let source: Source = .outlook

    var isConfigured: Bool {
        Keychain.get(Keychain.Key.outlookRefresh) != nil
    }

    func fetch() async throws -> [RawItem] {
        guard let token = await MicrosoftOAuth.validAccessToken() else { return [] }

        var comps = URLComponents(string: "https://graph.microsoft.com/v1.0/me/mailFolders/Inbox/messages")!
        comps.queryItems = [
            .init(name: "$filter", value: "isRead eq false"),
            .init(name: "$select", value: "id,subject,from,bodyPreview,receivedDateTime,webLink"),
            .init(name: "$top", value: "25"),
            .init(name: "$orderby", value: "receivedDateTime desc"),
        ]
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw SourceError(source: source,
                              message: "HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0) \(String(data: data, encoding: .utf8)?.prefix(200) ?? "")")
        }

        struct ListResp: Decodable {
            let value: [Msg]
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
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let parsed = try decoder.decode(ListResp.self, from: data)
        return parsed.value.map { m in
            let senderName = m.from?.emailAddress?.name
            let senderAddr = m.from?.emailAddress?.address
            let sender: String? = {
                if let n = senderName, !n.isEmpty { return "\(n) <\(senderAddr ?? "")>" }
                return senderAddr
            }()
            return RawItem(
                id: m.id,
                source: .outlook,
                title: m.subject ?? "(no subject)",
                sender: sender,
                snippet: String((m.bodyPreview ?? "").prefix(500)),
                url: m.webLink.flatMap { URL(string: $0) },
                receivedAt: m.receivedDateTime,
                isUnread: true
            )
        }
    }
}
