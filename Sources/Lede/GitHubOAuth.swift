import Foundation
import AppKit

/// GitHub OAuth App device flow — public client, no secret needed.
/// Using an OAuth App (not a GitHub App) because user-wide
/// `GET /notifications` is not accessible to GitHub App integrations.
/// Enable "Device Flow" on the OAuth App before it works.
enum GitHubOAuth {
    struct DeviceCode: Decodable {
        let device_code: String
        let user_code: String
        let verification_uri: String
        let expires_in: Int
        let interval: Int
    }

    enum TokenResult {
        case token(String)
        case pending(retryAfter: Int)
        case slowDown(retryAfter: Int)
        case expired
        case denied
        case error(String)
    }

    /// (provider-stable id, human-readable label) returned by `identity(token:)`.
    /// For GitHub these are both the user's login, but the type stays parallel
    /// to the other providers' identity discovery.
    struct Identity {
        let id: String
        let label: String
    }

    static let scopes = "notifications"

    /// The Lede OAuth App's public Client ID. Safe to embed — Client IDs are
    /// public identifiers. Users just click Connect; no config required.
    /// Must be an OAuth App (not a GitHub App) because `GET /notifications`
    /// isn't accessible to GitHub App integrations.
    static let clientID = "Ov23liyW7qnk6ZbDJLeu"

    /// Step 1: request a device + user code.
    static func requestDeviceCode(clientID: String = clientID) async throws -> DeviceCode {
        var req = URLRequest(url: URL(string: "https://github.com/login/device/code")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "accept")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "content-type")
        req.httpBody = "client_id=\(clientID)&scope=\(scopes)".data(using: .utf8)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw OAuthError.http((resp as? HTTPURLResponse)?.statusCode ?? 0,
                                  String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(DeviceCode.self, from: data)
    }

    /// Step 2: open the browser to `verification_uri` so the user pastes the user_code.
    static func openVerificationPage(_ code: DeviceCode) {
        // Using the URL with pre-filled code = smoother UX.
        if var comps = URLComponents(string: code.verification_uri) {
            comps.queryItems = [URLQueryItem(name: "user_code", value: code.user_code)]
            if let url = comps.url { NSWorkspace.shared.open(url); return }
        }
        NSWorkspace.shared.open(URL(string: code.verification_uri)!)
    }

    /// Step 3: poll every `interval` seconds until the user approves or we give up.
    /// Returns the access token once granted.
    static func pollForToken(clientID: String = clientID, deviceCode: DeviceCode) async throws -> String {
        var interval = deviceCode.interval
        let deadline = Date().addingTimeInterval(Double(deviceCode.expires_in))

        while Date() < deadline {
            try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
            switch try await pollOnce(clientID: clientID, deviceCode: deviceCode.device_code) {
            case .token(let t): return t
            case .pending: continue
            case .slowDown(let r): interval = max(interval, r)
            case .expired: throw OAuthError.http(410, "device code expired — try again")
            case .denied: throw OAuthError.http(403, "access denied on GitHub")
            case .error(let s): throw OAuthError.http(400, s)
            }
        }
        throw OAuthError.http(408, "timed out waiting for approval")
    }

    private static func pollOnce(clientID: String, deviceCode: String) async throws -> TokenResult {
        var req = URLRequest(url: URL(string: "https://github.com/login/oauth/access_token")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "accept")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "content-type")
        let body = "client_id=\(clientID)&device_code=\(deviceCode)&grant_type=urn:ietf:params:oauth:grant-type:device_code"
        req.httpBody = body.data(using: .utf8)

        let (data, _) = try await URLSession.shared.data(for: req)
        struct Resp: Decodable {
            let access_token: String?
            let error: String?
            let interval: Int?
        }
        let parsed = try JSONDecoder().decode(Resp.self, from: data)
        if let token = parsed.access_token { return .token(token) }
        switch parsed.error ?? "" {
        case "authorization_pending": return .pending(retryAfter: parsed.interval ?? 5)
        case "slow_down": return .slowDown(retryAfter: parsed.interval ?? 10)
        case "expired_token": return .expired
        case "access_denied": return .denied
        case let other: return .error(other)
        }
    }

    /// GET /user → discover the login (used as Account.id) and a label. Called
    /// after a successful token exchange (device flow OR PAT save) so we know
    /// which Account to file the credential under.
    static func identity(token: String) async throws -> Identity {
        var req = URLRequest(url: URL(string: "https://api.github.com/user")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Lede/0.1", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw OAuthError.http((resp as? HTTPURLResponse)?.statusCode ?? 0,
                                  String(data: data, encoding: .utf8) ?? "")
        }
        struct User: Decodable { let login: String; let name: String? }
        let u = try JSONDecoder().decode(User.self, from: data)
        let label = (u.name?.isEmpty == false ? u.name! : u.login)
        return Identity(id: u.login, label: label)
    }

    static func persistOAuth(token: String, accountID: String) {
        Keychain.set(token, for: Keychain.Key.githubAccess(accountID))
    }

    static func persistPAT(token: String, accountID: String) {
        Keychain.set(token, for: Keychain.Key.githubPAT(accountID))
    }

    static func signOut(accountID: String) {
        Keychain.delete(Keychain.Key.githubAccess(accountID))
        Keychain.delete(Keychain.Key.githubPAT(accountID))
    }

    /// Read whichever credential exists (OAuth bearer first, PAT fallback).
    static func token(forAccount accountID: String) -> String? {
        Keychain.get(Keychain.Key.githubAccess(accountID))
            ?? Keychain.get(Keychain.Key.githubPAT(accountID))
    }
}
