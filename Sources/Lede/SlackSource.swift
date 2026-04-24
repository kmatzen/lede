import Foundation
import AppKit
import CryptoKit

/// Slack OAuth 2.0 (v2) for a *user* token. Slack doesn't offer public
/// read-your-messages APIs without a registered app, so the user has to
/// create a Slack app on their workspace and supply client_id + client_secret.
///
/// Minimal app setup:
///   1. https://api.slack.com/apps → Create New App → From scratch
///   2. OAuth & Permissions → Add Redirect URL: http://localhost/oauth/slack
///      (the actual port is ephemeral; Slack accepts any port as long as the
///      scheme+host+path match — so register that URL then we vary the port)
///   3. User Token Scopes: channels:history, groups:history, im:history,
///      mpim:history, users:read, channels:read, groups:read, im:read, mpim:read
///   4. Install to workspace — copy Client ID + Client Secret into Settings.
enum SlackOAuth {
    static let authorizeURL = URL(string: "https://slack.com/oauth/v2/authorize")!
    static let tokenURL = URL(string: "https://slack.com/api/oauth.v2.access")!
    static let userScopes = "channels:history,groups:history,im:history,mpim:history,users:read,channels:read,groups:read,im:read,mpim:read"

    struct AuthResponse: Decodable {
        let ok: Bool
        let error: String?
        let authed_user: AuthedUser?
        struct AuthedUser: Decodable {
            let access_token: String?
        }
    }

    static func connect(clientID: String, clientSecret: String) async throws -> String {
        // Slack's registered redirect must match exactly, but only on scheme+host+path —
        // port is compared. So the registered URL pre-declares the port; we re-use it here.
        // For zero-config we use 53682 (matches what many CLIs register).
        let server = LoopbackOAuthServer()
        let port = try await server.start()
        defer { server.stop() }

        let redirect = "http://localhost:\(port)/oauth/slack"
        let state = randomHex(16)

        var comps = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "user_scope", value: userScopes),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "state", value: state),
        ]
        NSWorkspace.shared.open(comps.url!)

        let cb = try await server.waitForCallback()
        if let e = cb.error { throw OAuthError.http(400, e) }
        guard let code = cb.code, cb.state == state else {
            throw OAuthError.http(400, "Slack callback missing code/state")
        }

        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "content-type")
        let form = [
            "client_id": clientID,
            "client_secret": clientSecret,
            "code": code,
            "redirect_uri": redirect,
        ]
        req.httpBody = form
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw OAuthError.http((resp as? HTTPURLResponse)?.statusCode ?? 0,
                                  String(data: data, encoding: .utf8) ?? "")
        }
        let parsed = try JSONDecoder().decode(AuthResponse.self, from: data)
        guard parsed.ok, let token = parsed.authed_user?.access_token else {
            throw OAuthError.http(400, parsed.error ?? "unknown Slack error")
        }
        return token
    }

    static func signOut() {
        Keychain.delete(Keychain.Key.slackAccess)
    }

    private static func randomHex(_ bytes: Int) -> String {
        var b = Data(count: bytes)
        _ = b.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        return b.map { String(format: "%02x", $0) }.joined()
    }
}

struct SlackSource: NotificationSource {
    let source: Source = .slack

    var isConfigured: Bool { Keychain.get(Keychain.Key.slackAccess) != nil }

    func fetch() async throws -> [RawItem] {
        guard let token = Keychain.get(Keychain.Key.slackAccess) else { return [] }

        // Strategy: pull conversations.list (user's DMs + channels), pick ones with
        // unread_count_display > 0, then grab the last message from each. Keeps
        // token volume tiny — we only LLM-triage unread conversations.
        let convos = try await Self.conversations(token: token)
        let unread = convos.filter { ($0.unread_count_display ?? 0) > 0 }
        let userCache = await Self.userNameCache(token: token)

        return try await withThrowingTaskGroup(of: RawItem?.self) { group in
            for c in unread {
                group.addTask { try await Self.buildItem(channel: c, token: token, users: userCache) }
            }
            var out: [RawItem] = []
            for try await item in group { if let item { out.append(item) } }
            return out
        }
    }

    // MARK: -

    private struct Conversation: Decodable {
        let id: String
        let name: String?
        let is_im: Bool?
        let is_mpim: Bool?
        let is_channel: Bool?
        let user: String?
        let unread_count_display: Int?
    }

    private static func conversations(token: String) async throws -> [Conversation] {
        var comps = URLComponents(string: "https://slack.com/api/users.conversations")!
        comps.queryItems = [
            .init(name: "types", value: "public_channel,private_channel,im,mpim"),
            .init(name: "exclude_archived", value: "true"),
            .init(name: "limit", value: "100"),
        ]
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: req)
        struct Resp: Decodable { let ok: Bool; let channels: [Conversation]?; let error: String? }
        let parsed = try JSONDecoder().decode(Resp.self, from: data)
        guard parsed.ok else {
            throw SourceError(source: .slack, message: parsed.error ?? "users.conversations failed")
        }
        return parsed.channels ?? []
    }

    private static func userNameCache(token: String) async -> [String: String] {
        var req = URLRequest(url: URL(string: "https://slack.com/api/users.list?limit=200")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return [:] }
        struct Resp: Decodable {
            let ok: Bool
            let members: [Member]?
            struct Member: Decodable {
                let id: String
                let name: String?
                let real_name: String?
                struct Profile: Decodable { let display_name: String? }
                let profile: Profile?
            }
        }
        guard let parsed = try? JSONDecoder().decode(Resp.self, from: data), parsed.ok else { return [:] }
        var out: [String: String] = [:]
        for m in parsed.members ?? [] {
            out[m.id] = m.profile?.display_name?.nilIfEmpty ?? m.real_name ?? m.name ?? m.id
        }
        return out
    }

    private static func buildItem(channel: Conversation, token: String, users: [String: String]) async throws -> RawItem? {
        // Fetch last message in that conversation.
        var comps = URLComponents(string: "https://slack.com/api/conversations.history")!
        comps.queryItems = [
            .init(name: "channel", value: channel.id),
            .init(name: "limit", value: "1"),
        ]
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: req)
        struct Resp: Decodable {
            let ok: Bool
            let messages: [Msg]?
            struct Msg: Decodable {
                let text: String?
                let user: String?
                let ts: String?
            }
        }
        guard let parsed = try? JSONDecoder().decode(Resp.self, from: data),
              parsed.ok, let msg = parsed.messages?.first else { return nil }

        let sender = msg.user.flatMap { users[$0] } ?? msg.user
        let channelName: String = {
            if channel.is_im == true, let u = channel.user { return "DM: \(users[u] ?? u)" }
            if channel.is_mpim == true { return "Group DM" }
            if let n = channel.name { return "#\(n)" }
            return channel.id
        }()
        let received: Date = {
            if let ts = msg.ts, let t = Double(ts.split(separator: ".").first.map(String.init) ?? "") {
                return Date(timeIntervalSince1970: t)
            }
            return Date()
        }()

        return RawItem(
            id: "\(channel.id):\(msg.ts ?? "")",
            source: .slack,
            title: channelName,
            sender: sender,
            snippet: String((msg.text ?? "").prefix(500)),
            url: URL(string: "slack://channel?team=&id=\(channel.id)"),
            receivedAt: received,
            isUnread: true
        )
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
