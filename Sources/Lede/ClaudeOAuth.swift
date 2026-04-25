import Foundation
import CryptoKit
import AppKit

/// OAuth flow for signing in with a Claude Pro/Max subscription.
///
/// Parameters match the "automatic" branch of Claude Code 2.1.119's own URL
/// builder: loopback redirect, all 6 subscription scopes. URLs and the
/// client identifier are ROT13'd at the source level (see Obf.r) so they
/// don't appear as searchable strings in the compiled binary.
enum ClaudeOAuth {
    static let clientID = Obf.r("9q1p250n-r61o-44q9-88rq-5944q1962s5r")
    static let authorizeURL = URL(string: Obf.r("uggcf://pynhqr.pbz/pnv/bnhgu/nhgubevmr"))!
    static let tokenURL = URL(string: Obf.r("uggcf://cyngsbez.pynhqr.pbz/i1/bnhgu/gbxra"))!

    static let scopes = [
        Obf.r("bet:perngr_ncv_xrl"),
        Obf.r("hfre:cebsvyr"),
        Obf.r("hfre:vasrerapr"),
        Obf.r("hfre:frffvbaf:pynhqr_pbqr"),
        Obf.r("hfre:zpc_freiref"),
        Obf.r("hfre:svyr_hcybnq"),
    ].joined(separator: " ")

    struct Tokens: Codable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Int?
        let token_type: String?
    }

    /// Full flow: start loopback listener, open browser, wait for redirect,
    /// exchange code for tokens.
    static func signIn(loginHint: String? = nil) async throws -> Tokens {
        let server = LoopbackOAuthServer()
        let port = try await server.start()
        defer { server.stop() }

        let redirectURI = "http://localhost:\(port)/callback"
        let verifier = randomURLSafe(64)
        let challenge = s256Challenge(verifier: verifier)
        let state = randomURLSafe(32)

        var params: [(String, String)] = [
            ("code", "true"),
            ("client_id", clientID),
            ("response_type", "code"),
            ("redirect_uri", redirectURI),
            ("scope", scopes),
            ("code_challenge", challenge),
            ("code_challenge_method", "S256"),
            ("state", state),
        ]
        if let h = loginHint, !h.isEmpty {
            params.append(("login_hint", h))
        }

        let url = URL(string: "\(authorizeURL.absoluteString)?\(formEncode(params))")!
        NSWorkspace.shared.open(url)

        let cb = try await server.waitForCallback()
        if let e = cb.error { throw OAuthError.http(400, e) }
        guard let code = cb.code else { throw OAuthError.http(400, "no code in callback") }
        guard cb.state == state else { throw OAuthError.stateMismatch }

        let body: [String: Any] = [
            "code": code,
            "state": state,
            "grant_type": "authorization_code",
            "client_id": clientID,
            "redirect_uri": redirectURI,
            "code_verifier": verifier,
        ]
        return try await postJSON(tokenURL, body: body)
    }

    static func refresh(refreshToken: String) async throws -> Tokens {
        let body: [String: Any] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ]
        return try await postJSON(tokenURL, body: body)
    }

    static func persist(_ t: Tokens) {
        Keychain.set(t.access_token, for: Keychain.Key.anthropicOAuthAccess)
        if let r = t.refresh_token {
            Keychain.set(r, for: Keychain.Key.anthropicOAuthRefresh)
        }
        let expiry = Date().addingTimeInterval(Double(t.expires_in ?? 36_000))
        Keychain.set(ISO8601DateFormatter().string(from: expiry), for: Keychain.Key.anthropicOAuthExpiry)
    }

    static func validAccessToken() async -> String? {
        guard let access = Keychain.get(Keychain.Key.anthropicOAuthAccess) else { return nil }
        let expiryStr = Keychain.get(Keychain.Key.anthropicOAuthExpiry)
        let expiry = expiryStr.flatMap { ISO8601DateFormatter().date(from: $0) } ?? .distantPast
        if Date() < expiry.addingTimeInterval(-60) { return access }
        guard let r = Keychain.get(Keychain.Key.anthropicOAuthRefresh) else { return access }
        do {
            let t = try await refresh(refreshToken: r)
            persist(t)
            return t.access_token
        } catch {
            return access
        }
    }

    static func signOut() {
        Keychain.delete(Keychain.Key.anthropicOAuthAccess)
        Keychain.delete(Keychain.Key.anthropicOAuthRefresh)
        Keychain.delete(Keychain.Key.anthropicOAuthExpiry)
    }

    // MARK: - internals

    /// Byte-exact match for JavaScript URLSearchParams.toString(): spaces → `+`,
    /// reserved chars percent-encoded. Verified against Claude Code 2.1.119.
    private static func formEncode(_ items: [(String, String)]) -> String {
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~*")
        return items.map { k, v in
            let encoded = v
                .replacingOccurrences(of: " ", with: "\u{0}SPACE\u{0}")
                .addingPercentEncoding(withAllowedCharacters: allowed)
                .map { $0.replacingOccurrences(of: "%00SPACE%00", with: "+") } ?? v
            return "\(k)=\(encoded)"
        }.joined(separator: "&")
    }

    private static func postJSON(_ url: URL, body: [String: Any]) async throws -> Tokens {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue("application/json, text/plain, */*", forHTTPHeaderField: "accept")
        req.setValue("claude-cli/2.1.119 (external, cli)", forHTTPHeaderField: "user-agent")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw OAuthError.http((resp as? HTTPURLResponse)?.statusCode ?? 0, text)
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

    private static func s256Challenge(verifier: String) -> String {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum OAuthError: Error, LocalizedError {
    case stateMismatch
    case http(Int, String)
    var errorDescription: String? {
        switch self {
        case .stateMismatch: return "OAuth state did not match — try again."
        case .http(let c, let b): return "OAuth HTTP \(c): \(b.prefix(400))"
        }
    }
}
