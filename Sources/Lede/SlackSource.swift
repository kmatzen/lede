import Foundation
import AppKit
import CryptoKit

/// Slack OAuth 2.0 (v2) — user token, loopback redirect.
///
/// Client ID + Secret are user-supplied (unlike Google's Desktop-app OAuth,
/// Slack considers client secrets private). Create an app from
/// Resources/slack-app-manifest.yml and paste its creds in Settings.
enum SlackOAuth {
    static let authorizeURL = URL(string: "https://slack.com/oauth/v2/authorize")!
    static let tokenURL = URL(string: "https://slack.com/api/oauth.v2.access")!
    static let userScopes = "channels:history,groups:history,im:history,mpim:history,users:read,channels:read,groups:read,im:read,mpim:read"

    struct AuthResponse: Decodable {
        let ok: Bool
        let error: String?
        let authed_user: AuthedUser?
        let team: Team?
        struct AuthedUser: Decodable { let id: String?; let access_token: String? }
        struct Team: Decodable { let id: String? }
    }

    /// Returns the user access token, user_id, and team_id so the source can
    /// resolve @mentions and build deep-links.
    struct Credentials {
        let accessToken: String
        let userID: String?
        let teamID: String?
    }

    static func connect(clientID: String, clientSecret: String) async throws -> Credentials {
        let server = LoopbackOAuthServer()
        let port = try await server.start()
        defer { server.stop() }

        // Slack matches redirect_uri on scheme+host+path, ignoring the port.
        // Register `http://localhost` once; we vary the port.
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
        return Credentials(
            accessToken: token,
            userID: parsed.authed_user?.id,
            teamID: parsed.team?.id
        )
    }

    static func persist(_ c: Credentials) {
        Keychain.set(c.accessToken, for: Keychain.Key.slackAccess)
        if let u = c.userID { Keychain.set(u, for: Keychain.Key.slackUserID) }
        if let t = c.teamID { Keychain.set(t, for: Keychain.Key.slackTeamID) }
    }

    static func signOut() {
        Keychain.delete(Keychain.Key.slackAccess)
        Keychain.delete(Keychain.Key.slackUserID)
        Keychain.delete(Keychain.Key.slackTeamID)
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
        let userID = Keychain.get(Keychain.Key.slackUserID)
        let teamID = Keychain.get(Keychain.Key.slackTeamID)

        // Pull every conversation the user participates in (paginated), then
        // only look at the ones with unread messages. Keeps volume bounded.
        let convos = try await Self.allConversations(token: token)
        let unread = convos.filter { ($0.unread_count_display ?? 0) > 0 }
        Log.info("slack: \(convos.count) conversation(s), \(unread.count) unread")
        let users = await Self.userNameCache(token: token)

        return try await withThrowingTaskGroup(of: RawItem?.self) { group in
            for c in unread {
                group.addTask {
                    try await Self.buildItem(channel: c, token: token, users: users,
                                             userID: userID, teamID: teamID)
                }
            }
            var out: [RawItem] = []
            for try await item in group { if let item { out.append(item) } }
            return out
        }
    }

    // MARK: - Conversations

    private struct Conversation: Decodable {
        let id: String
        let name: String?
        let is_im: Bool?
        let is_mpim: Bool?
        let is_channel: Bool?
        let user: String?  // DM partner user id
        let unread_count_display: Int?
    }

    /// Paginate through every conversation the user is a member of.
    /// Cap at a reasonable total so a very large workspace doesn't lock us up.
    private static func allConversations(token: String) async throws -> [Conversation] {
        var all: [Conversation] = []
        var cursor: String? = nil
        let maxTotal = 500
        repeat {
            var comps = URLComponents(string: "https://slack.com/api/users.conversations")!
            var items: [URLQueryItem] = [
                .init(name: "types", value: "public_channel,private_channel,im,mpim"),
                .init(name: "exclude_archived", value: "true"),
                .init(name: "limit", value: "200"),
            ]
            if let c = cursor { items.append(.init(name: "cursor", value: c)) }
            comps.queryItems = items

            let (data, resp): (Data, URLResponse) = try await slackGet(comps.url!, token: token)
            if let http = resp as? HTTPURLResponse, http.statusCode == 429 {
                // Rate-limited. Honor Retry-After and try once more.
                let wait = Int(http.value(forHTTPHeaderField: "Retry-After") ?? "1") ?? 1
                try await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000_000)
                continue
            }
            struct Resp: Decodable {
                let ok: Bool
                let channels: [Conversation]?
                let error: String?
                let response_metadata: Meta?
                struct Meta: Decodable { let next_cursor: String? }
            }
            let parsed = try JSONDecoder().decode(Resp.self, from: data)
            guard parsed.ok else {
                throw SourceError(source: .slack, message: parsed.error ?? "users.conversations failed")
            }
            all.append(contentsOf: parsed.channels ?? [])
            let next = parsed.response_metadata?.next_cursor ?? ""
            cursor = next.isEmpty ? nil : next
        } while cursor != nil && all.count < maxTotal
        return all
    }

    // MARK: - User directory

    private static func userNameCache(token: String) async -> [String: String] {
        var all: [String: String] = [:]
        var cursor: String? = nil
        repeat {
            var comps = URLComponents(string: "https://slack.com/api/users.list")!
            var items: [URLQueryItem] = [.init(name: "limit", value: "200")]
            if let c = cursor { items.append(.init(name: "cursor", value: c)) }
            comps.queryItems = items

            guard let (data, _) = try? await slackGet(comps.url!, token: token) else { return all }
            struct Resp: Decodable {
                let ok: Bool
                let members: [Member]?
                let response_metadata: Meta?
                struct Meta: Decodable { let next_cursor: String? }
                struct Member: Decodable {
                    let id: String
                    let name: String?
                    let real_name: String?
                    struct Profile: Decodable { let display_name: String? }
                    let profile: Profile?
                }
            }
            guard let parsed = try? JSONDecoder().decode(Resp.self, from: data), parsed.ok else { return all }
            for m in parsed.members ?? [] {
                all[m.id] = m.profile?.display_name?.nilIfEmpty ?? m.real_name ?? m.name ?? m.id
            }
            let next = parsed.response_metadata?.next_cursor ?? ""
            cursor = next.isEmpty ? nil : next
        } while cursor != nil && all.count < 2000
        return all
    }

    // MARK: - Messages

    private static func buildItem(channel: Conversation,
                                  token: String,
                                  users: [String: String],
                                  userID: String?,
                                  teamID: String?) async throws -> RawItem? {
        var comps = URLComponents(string: "https://slack.com/api/conversations.history")!
        comps.queryItems = [
            .init(name: "channel", value: channel.id),
            .init(name: "limit", value: "1"),
        ]
        guard let (data, _) = try? await slackGet(comps.url!, token: token) else { return nil }
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

        // Rewrite Slack entity tokens into readable text for the LLM:
        //   <@U123>  → @me (if it's the signed-in user), else @DisplayName
        //   <#C123|general> → #general
        //   <!here>, <!channel>, <!everyone> → @here / @channel / @everyone
        let snippet = rewriteEntities(msg.text ?? "", users: users, selfID: userID)

        // Direct-link that opens the Slack desktop app at the message:
        //   slack://channel?team=T123&id=C456&message=1700000000.000100
        // Fall back to web URL if we don't have team id.
        let url: URL? = {
            var parts: [URLQueryItem] = [
                .init(name: "team", value: teamID ?? ""),
                .init(name: "id", value: channel.id),
            ]
            if let ts = msg.ts { parts.append(.init(name: "message", value: ts)) }
            var c = URLComponents()
            c.scheme = "slack"
            c.host = "channel"
            c.queryItems = parts
            return c.url
        }()

        return RawItem(
            id: "\(channel.id):\(msg.ts ?? "")",
            source: .slack,
            title: channelName,
            sender: sender,
            snippet: String(snippet.prefix(500)),
            url: url,
            receivedAt: received,
            isUnread: true
        )
    }

    // MARK: - Helpers

    /// Slack messages use `<@U123>`, `<#C123|name>`, and `<!here>` tokens.
    /// The triage LLM doesn't know those — translate to human form, and mark
    /// the signed-in user as `@me` so the triage rubric's @mention boost fires.
    private static func rewriteEntities(_ text: String, users: [String: String], selfID: String?) -> String {
        var out = text

        // <@USERID> or <@USERID|label>
        let userPattern = try! NSRegularExpression(pattern: "<@([A-Z0-9]+)(?:\\|[^>]+)?>")
        out = substitute(out, pattern: userPattern) { match, src in
            let id = (src as NSString).substring(with: match.range(at: 1))
            if let self_ = selfID, id == self_ { return "@me" }
            if let name = users[id] { return "@\(name)" }
            return "@\(id)"
        }

        // <#CHANNELID|name>  or <#CHANNELID>
        let channelPattern = try! NSRegularExpression(pattern: "<#([A-Z0-9]+)(?:\\|([^>]+))?>")
        out = substitute(out, pattern: channelPattern) { match, src in
            if match.range(at: 2).location != NSNotFound {
                return "#" + (src as NSString).substring(with: match.range(at: 2))
            }
            return "#channel"
        }

        // <!here>, <!channel>, <!everyone>, <!subteam^ID|label>
        let bangPattern = try! NSRegularExpression(pattern: "<!([^>|]+)(?:\\|([^>]+))?>")
        out = substitute(out, pattern: bangPattern) { match, src in
            let keyword = (src as NSString).substring(with: match.range(at: 1))
            if match.range(at: 2).location != NSNotFound {
                return "@" + (src as NSString).substring(with: match.range(at: 2))
            }
            return "@\(keyword)"
        }

        return out
    }

    private static func substitute(_ input: String,
                                   pattern: NSRegularExpression,
                                   replace: (NSTextCheckingResult, String) -> String) -> String {
        let ns = input as NSString
        var result = ""
        var cursor = 0
        for match in pattern.matches(in: input, range: NSRange(location: 0, length: ns.length)) {
            let r = match.range
            result += ns.substring(with: NSRange(location: cursor, length: r.location - cursor))
            result += replace(match, input)
            cursor = r.location + r.length
        }
        result += ns.substring(from: cursor)
        return result
    }

    /// Wrap URLSession with Slack's OAuth bearer header. Returns raw data + response
    /// so callers can inspect 429s etc.
    private static func slackGet(_ url: URL, token: String) async throws -> (Data, URLResponse) {
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return try await URLSession.shared.data(for: req)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
