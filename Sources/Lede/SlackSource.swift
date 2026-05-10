import Foundation
import AppKit
import CryptoKit

/// Slack OAuth 2.0 (v2) — user token, loopback redirect.
///
/// Each Slack workspace requires its own app registration (Slack doesn't allow
/// generic third-party reading apps). The user pastes the workspace's client
/// id + secret from the manifest at Resources/slack-app-manifest.yml; those
/// creds + the resulting access token are persisted per-workspace, keyed by
/// the team id discovered during OAuth.
enum SlackOAuth {
    static let authorizeURL = URL(string: "https://slack.com/oauth/v2/authorize")!
    static let tokenURL = URL(string: "https://slack.com/api/oauth.v2.access")!
    /// `search:read` is what makes the new `search.messages?query=is:unread`
    /// path work — that single call replaces the old conversations.info-per-
    /// channel approach. `users:read` resolves @mentions to display names.
    /// History/read scopes per channel type are kept so `rewriteEntities`
    /// can decode `<@U…>` tokens cheaply via users.list.
    static let userScopes = "channels:history,groups:history,im:history,mpim:history,users:read,channels:read,groups:read,im:read,mpim:read,search:read"
    /// Slack matches `redirect_uri` strictly (scheme+host+port+path), so the
    /// loopback server must bind a fixed port. Users register exactly
    /// `http://localhost:\(redirectPort)\(redirectPath)` in their Slack app
    /// once and never need to update it. The manifest in
    /// `Resources/slack-app-manifest.yml` keeps these values in sync.
    static let redirectPort: UInt16 = 53682
    static let redirectPath = "/oauth/slack"

    struct AuthResponse: Decodable {
        let ok: Bool
        let error: String?
        let authed_user: AuthedUser?
        let team: Team?
        struct AuthedUser: Decodable { let id: String?; let access_token: String? }
        struct Team: Decodable { let id: String?; let name: String? }
    }

    struct ConnectResult {
        let teamID: String          // Account.id
        let teamName: String        // Account.label
        let userID: String?
        let accessToken: String
    }

    static func connect(clientID: String, clientSecret: String) async throws -> ConnectResult {
        let server = LoopbackOAuthServer()
        _ = try await server.start(preferredPort: redirectPort)
        defer { server.stop() }

        let redirect = "http://localhost:\(redirectPort)\(redirectPath)"
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
        guard parsed.ok,
              let token = parsed.authed_user?.access_token,
              let teamID = parsed.team?.id else {
            throw OAuthError.http(400, parsed.error ?? "unknown Slack error")
        }
        return ConnectResult(
            teamID: teamID,
            teamName: parsed.team?.name ?? teamID,
            userID: parsed.authed_user?.id,
            accessToken: token
        )
    }

    /// Persist per-workspace creds. The clientID/secret are kept too because
    /// each workspace has its own pair and we need them for any future re-auth.
    static func persist(_ r: ConnectResult, clientID: String, clientSecret: String) {
        Keychain.set(r.accessToken, for: Keychain.Key.slackAccess(r.teamID))
        Keychain.set(clientID, for: Keychain.Key.slackClientID(r.teamID))
        Keychain.set(clientSecret, for: Keychain.Key.slackClientSecret(r.teamID))
        if let u = r.userID {
            Keychain.set(u, for: Keychain.Key.slackUserID(r.teamID))
        }
    }

    static func signOut(accountID: String) {
        Keychain.delete(Keychain.Key.slackAccess(accountID))
        Keychain.delete(Keychain.Key.slackClientID(accountID))
        Keychain.delete(Keychain.Key.slackClientSecret(accountID))
        Keychain.delete(Keychain.Key.slackUserID(accountID))
        // Cleanup of pre-v0.1.18 starred-cache UserDefaults keys. Harmless if
        // already absent. Kept for one release cycle; can be removed later.
        UserDefaults.standard.removeObject(forKey: "lede.slack.\(accountID).starredCache")
        UserDefaults.standard.removeObject(forKey: "lede.slack.\(accountID).autoDiscoveryInitiated")
    }

    private static func randomHex(_ bytes: Int) -> String {
        var b = Data(count: bytes)
        _ = b.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        return b.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Per-workspace prefs

/// User-controllable knobs for what to surface from a Slack workspace.
///
/// With the `search.messages?query=is:unread` approach in v0.1.18+, prefs are
/// pure client-side filters on the unread results Slack already returns —
/// they no longer drive *what* we probe (Slack handles that), only *which
/// types of unread results* we keep.
struct SlackPrefs {
    let teamID: String

    enum ChannelMode: String {
        case off
        case mentions
        case all
    }

    var includeDMs: Bool {
        get { boolDefault("includeDMs", default: true) }
        nonmutating set { setBool("includeDMs", newValue) }
    }
    var includeMPIMs: Bool {
        get { boolDefault("includeMPIMs", default: true) }
        nonmutating set { setBool("includeMPIMs", newValue) }
    }
    /// "Include channel results" toggle. `is:unread` already filters to
    /// messages Slack thinks are notification-worthy, so the older
    /// "starred vs. mentions vs. all" distinction collapses to one flag.
    var includeStarred: Bool {
        get { boolDefault("includeStarred", default: true) }
        nonmutating set { setBool("includeStarred", newValue) }
    }
    /// Retained so existing UserDefaults from pre-v0.1.18 don't break. Any
    /// non-`.off` value contributes to the channel-include decision below.
    var channelMode: ChannelMode {
        get {
            let raw = UserDefaults.standard.string(forKey: key("channelMode")) ?? ""
            return ChannelMode(rawValue: raw) ?? .off
        }
        nonmutating set { UserDefaults.standard.set(newValue.rawValue, forKey: key("channelMode")) }
    }

    var allowlistRaw: String {
        get { UserDefaults.standard.string(forKey: key("allowlist")) ?? "" }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: key("allowlist")) }
    }
    var denylistRaw: String {
        get { UserDefaults.standard.string(forKey: key("denylist")) ?? "" }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: key("denylist")) }
    }
    var allowlist: Set<String> { Self.parseList(allowlistRaw) }
    var denylist: Set<String> { Self.parseList(denylistRaw) }

    private func key(_ name: String) -> String { "lede.slack.\(teamID).\(name)" }
    private func boolDefault(_ name: String, default fallback: Bool) -> Bool {
        let k = key(name)
        if UserDefaults.standard.object(forKey: k) == nil { return fallback }
        return UserDefaults.standard.bool(forKey: k)
    }
    private func setBool(_ name: String, _ value: Bool) {
        UserDefaults.standard.set(value, forKey: key(name))
    }
    static func parseList(_ raw: String) -> Set<String> {
        Set(raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .map { $0.hasPrefix("#") ? String($0.dropFirst()) : $0 }
            .filter { !$0.isEmpty })
    }
}

// MARK: - Source

struct SlackSource: NotificationSource {
    let account: Account
    let source: Source = .slack

    var isConfigured: Bool {
        Keychain.get(Keychain.Key.slackAccess(account.id)) != nil
    }

    fileprivate struct SearchResp: Decodable {
        let ok: Bool
        let error: String?
        /// Slack returns `needed` and `provided` scopes when search:read
        /// is missing — surface that into our error message rather than
        /// the generic "missing_scope".
        let needed: String?
        let provided: String?
        /// Non-fatal warnings — e.g. `superfluous_charset` or scope
        /// hints — surfaced in the log when no matches come back so
        /// we can tell "Slack is happy but the index is empty" from
        /// "Slack quietly downgraded the query".
        let warning: String?
        let response_metadata: ResponseMeta?
        let messages: Messages?
        struct ResponseMeta: Decodable {
            let warnings: [String]?
            let messages: [String]?
        }
        struct Messages: Decodable {
            let matches: [Match]?
            let total: Int?
            /// Slack search includes a `paging` block with `pages` and
            /// `page`; we use it to know when we've drained the cursor.
            let paging: Paging?
            struct Paging: Decodable {
                let page: Int?
                let pages: Int?
            }
        }
        struct Match: Decodable {
            let channel: Channel?
            let user: String?
            let username: String?
            let text: String?
            let ts: String?
            let permalink: String?
            struct Channel: Decodable {
                let id: String
                let name: String?
                let is_im: Bool?
                let is_mpim: Bool?
                let is_private: Bool?
            }
        }
    }

    func fetch() async throws -> FetchResult {
        guard let token = Keychain.get(Keychain.Key.slackAccess(account.id)) else {
            return FetchResult(items: [])
        }
        let userID = Keychain.get(Keychain.Key.slackUserID(account.id))
        let prefs = SlackPrefs(teamID: account.id)

        // Strategy: 3 search.messages queries + 1 conversations-API
        // fallback. The search-based queries are cheap and serve the
        // common case; the conversations API is the safety net for what
        // search-by-content silently drops (notably bot integrations).
        //
        //   1. `is:unread` — Slack's "give me my notifications" filter.
        //      Catches human-authored unread channel messages, DMs, and
        //      mentions.
        //
        //   2. `from:@slackbot after:<recent>` — `is:unread` silently
        //      excludes Slackbot-authored messages even when they're
        //      genuinely unread, so reminders fired via /remind never
        //      appear via query #1. We pull recent Slackbot messages
        //      separately and dedupe by ts. The recency window keeps us
        //      from dredging up old, already-handled reminders.
        //
        //   3. `is:unread in:thread` — replies in threads the user is
        //      following have their own unread tracking, separate from the
        //      channel-level state `is:unread` keys off. The per-fetch log
        //      line doubles as permanent observability into how often
        //      thread replies are the only thing we'd be returning.
        //
        //   4. Conversations API (users.conversations + conversations.info
        //      + conversations.history) — read-state-based, so it catches
        //      whatever Slack itself considers unread regardless of who
        //      authored it. Closes the bot-integration gap (PagerDuty,
        //      Datadog, Jira, custom webhooks) that no `from:` search
        //      query can enumerate without an adhoc allowlist.
        //
        // Walk `page=` on the unread query until either the soft cap is hit
        // or the cursor is exhausted. `count=100` is Slack's per-page max.
        // Both supplements are single-page — Slackbot is recency-bounded
        // and the thread-reply count per refresh is rarely > 100; if it
        // ever is, the log makes it visible and we can paginate later.
        let cap = SourcePagination.softCap
        var unread: [SearchResp.Match] = []
        var unreadTotal = 0
        var http: HTTPURLResponse!
        var parsed: SearchResp!
        var pages = 1
        var omitted = 0
        var page = 1
        while unread.count < cap {
            let result = try await searchMessages(
                query: "is:unread", count: 100, page: page, token: token
            )
            unread.append(contentsOf: result.matches)
            unreadTotal = result.total
            http = result.http
            parsed = result.parsed
            pages = result.parsed.messages?.paging?.pages ?? 1
            if page >= pages { break }
            page += 1
        }
        // Slack reports `total` even when `paging.pages` is missing or 1,
        // so use it as the source of truth — a `pages=1, total=250`
        // response (rare but observed) shouldn't silently lose 150 items.
        if unread.count > cap {
            unread = Array(unread.prefix(cap))
        }
        if unreadTotal > unread.count {
            omitted = max(omitted, unreadTotal - unread.count)
        }
        Log.info("slack[\(account.label)]: search.messages [is:unread] returned \(unread.count) of \(unreadTotal) message(s) across \(min(page, pages)) page(s)\(omitted > 0 ? " (cap hit, ≥\(omitted) more)" : "")")

        let after = Self.afterDateString(daysBack: 2)
        var slackbotMatches: [SearchResp.Match] = []
        do {
            let r = try await searchMessages(
                query: "from:@slackbot after:\(after)", count: 20, page: 1, token: token
            )
            Log.info("slack[\(account.label)]: search.messages [from:@slackbot after:\(after)] returned \(r.matches.count) of \(r.total) message(s)")
            slackbotMatches = r.matches
        } catch {
            // Don't fail the whole fetch over a supplementary query.
            Log.warn("slack[\(account.label)]: Slackbot supplement query failed: \(error.localizedDescription)")
        }

        var threadMatches: [SearchResp.Match] = []
        do {
            let r = try await searchMessages(
                query: "is:unread in:thread", count: 100, page: 1, token: token
            )
            // Permanent diagnostic — `total` is what `is:unread in:thread`
            // says the workspace has right now. Compared against the
            // unread-query total this is how we tell whether channel-level
            // `is:unread` is silently dropping thread replies.
            Log.info("slack[\(account.label)]: search.messages [is:unread in:thread] returned \(r.matches.count) of \(r.total) message(s)")
            threadMatches = r.matches
        } catch {
            Log.warn("slack[\(account.label)]: thread supplement query failed: \(error.localizedDescription)")
        }

        // Conversations-API fallback: the bot-integration safety net.
        let conversationsMatches = await fetchConversationsAPIUnreads(prefs: prefs, token: token)

        // Merge + dedupe by (channel.id, ts). Keep `is:unread` ordering
        // first so messages also returned by other paths land where the
        // primary sort put them; supplements append the rest.
        var seen = Set<String>()
        var matches: [SearchResp.Match] = []
        for m in unread + slackbotMatches + threadMatches + conversationsMatches {
            let key = "\(m.channel?.id ?? "?"):\(m.ts ?? "?")"
            if seen.insert(key).inserted { matches.append(m) }
        }

        // Diagnostic: when both queries combined return zero, dump the
        // response headers + any warnings, then run the multi-query probe.
        // Useful for figuring out why a known-unread message doesn't appear
        // (often search indexing lag, sometimes a missing scope Slack
        // downgraded silently).
        if matches.isEmpty {
            let scopes = http.value(forHTTPHeaderField: "X-OAuth-Scopes") ?? "?"
            let acceptedScopes = http.value(forHTTPHeaderField: "X-Accepted-OAuth-Scopes") ?? "?"
            var bits: [String] = ["scopes=\(scopes)", "accepted=\(acceptedScopes)"]
            if let w = parsed.warning { bits.append("warning=\(w)") }
            if let ws = parsed.response_metadata?.warnings, !ws.isEmpty {
                bits.append("metaWarnings=\(ws.joined(separator: "|"))")
            }
            if let ms = parsed.response_metadata?.messages, !ms.isEmpty {
                bits.append("metaMessages=\(ms.joined(separator: "|"))")
            }
            Log.info("slack[\(account.label)]: zero-results diagnostics — \(bits.joined(separator: " "))")
            await probeSearchIndex(token: token, label: account.label)
        }

        // Resolve @mentions and DM partner names.
        let users = await Self.userNameCache(token: token)
        let acct = account
        let allow = prefs.allowlist
        let deny = prefs.denylist

        let items: [RawItem] = matches.compactMap { m -> RawItem? in
            guard let ch = m.channel, let ts = m.ts else { return nil }
            let isIM = ch.is_im == true
            let isMPIM = ch.is_mpim == true
            let isChannel = !isIM && !isMPIM
            let chName = (ch.name ?? "").lowercased()

            // Apply prefs.
            if !chName.isEmpty && deny.contains(chName) { return nil }
            let inAllowlist = !chName.isEmpty && allow.contains(chName)
            if !inAllowlist {
                if isIM, !prefs.includeDMs { return nil }
                if isMPIM, !prefs.includeMPIMs { return nil }
                if isChannel {
                    // `is:unread` already narrows to messages Slack considers
                    // notification-worthy (mentions, threads you follow, DMs,
                    // explicit star/keyword highlights). One toggle covers it.
                    let channelOK = prefs.includeStarred || prefs.channelMode != .off
                    if !channelOK { return nil }
                }
            }

            let senderID = m.user
            let senderName = senderID.flatMap { users[$0] } ?? m.username ?? senderID
            let title: String = {
                if isIM, let u = senderID { return "DM: \(users[u] ?? u)" }
                if isMPIM { return "Group DM" }
                return "#\(ch.name ?? ch.id)"
            }()
            let received: Date = {
                if let t = Double(ts.split(separator: ".").first.map(String.init) ?? "") {
                    return Date(timeIntervalSince1970: t)
                }
                return Date()
            }()
            let snippet = Self.rewriteEntities(m.text ?? "", users: users, selfID: userID)
            let url = m.permalink.flatMap { URL(string: $0) }

            return RawItem(
                id: "\(ch.id):\(ts)",
                source: .slack,
                accountID: acct.id,
                accountLabel: acct.label,
                title: title,
                sender: senderName,
                snippet: String(snippet.prefix(500)),
                url: url,
                receivedAt: received,
                isUnread: true
            )
        }
        return FetchResult(items: items, omitted: omitted)
    }

    /// One `search.messages` call. Returns the matches, the API-reported
    /// total, the raw HTTP response (so callers can inspect headers like
    /// `X-OAuth-Scopes`), and the parsed envelope (for warnings / metadata).
    /// Throws on transport, decode, or `ok=false` errors.
    private func searchMessages(query: String, count: Int, page: Int, token: String)
        async throws -> (matches: [SearchResp.Match], total: Int, http: HTTPURLResponse, parsed: SearchResp)
    {
        var comps = URLComponents(string: "https://slack.com/api/search.messages")!
        comps.queryItems = [
            .init(name: "query", value: query),
            .init(name: "count", value: String(count)),
            .init(name: "page", value: String(page)),
            .init(name: "sort", value: "timestamp"),
            .init(name: "sort_dir", value: "desc"),
        ]
        let (data, resp) = try await Self.slackGet(comps.url!, token: token)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw SourceError(source: .slack,
                              message: "search.messages HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0): \(body.prefix(200))")
        }
        let parsed: SearchResp
        do { parsed = try JSONDecoder().decode(SearchResp.self, from: data) }
        catch {
            let raw = String(data: data, encoding: .utf8) ?? ""
            Log.warn("slack[\(account.label)] search.messages decode failed: \(raw.prefix(400))")
            throw SourceError(source: .slack, message: "search.messages decode: \(error.localizedDescription)")
        }
        guard parsed.ok else {
            let detail = parsed.needed.map { "needed=\($0) provided=\(parsed.provided ?? "?")" } ?? ""
            throw SourceError(source: .slack,
                              message: "search.messages [\(query)]: \(parsed.error ?? "unknown") \(detail)")
        }
        return (parsed.messages?.matches ?? [], parsed.messages?.total ?? 0, http, parsed)
    }

    /// `YYYY-MM-DD` `daysBack` days before today (UTC). Used as the
    /// `after:` modifier on the Slackbot supplement query. Slack's `after:`
    /// is exclusive, so this returns messages from the day after the
    /// formatted date onward — close enough to "last N days" for a coarse
    /// recency filter.
    private static func afterDateString(daysBack: Int) -> String {
        let date = Calendar.current.date(byAdding: .day, value: -daysBack, to: Date()) ?? Date()
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }

    /// Diagnostic: probe `search.messages` with several query shapes to
    /// figure out *why* `is:unread` came back empty. We want to distinguish:
    ///
    ///   • search index is empty (workspace freshly created, indexing not
    ///     yet caught up) — every probe returns 0
    ///   • `is:unread` is over-filtering — `from:@me` / `from:@slackbot`
    ///     return >0, but `is:unread` returns 0
    ///   • Slackbot/system messages are excluded by `is:unread` — generic
    ///     queries return >0 but `from:@slackbot` returns 0
    ///
    /// All counts are logged together so the user can see the full picture.
    private func probeSearchIndex(token: String, label: String) async {
        let probes: [(String, String)] = [
            ("the",                "common word"),
            ("a",                  "single-letter"),
            ("from:@me",           "self-sent"),
            ("from:@slackbot",     "Slackbot-authored"),
            ("has:reminder",       "reminders"),
            ("in:thread",          "any thread reply"),
            ("is:unread in:thread","unread thread replies"),
        ]
        struct ProbeResp: Decodable {
            let ok: Bool
            let error: String?
            let messages: M?
            struct M: Decodable { let total: Int? }
        }
        for (q, descr) in probes {
            var comps = URLComponents(string: "https://slack.com/api/search.messages")!
            comps.queryItems = [
                .init(name: "query", value: q),
                .init(name: "count", value: "1"),
            ]
            guard let url = comps.url,
                  let (data, _) = try? await Self.slackGet(url, token: token),
                  let parsed = try? JSONDecoder().decode(ProbeResp.self, from: data) else {
                Log.info("slack[\(label)]: probe `\(q)` (\(descr)) HTTP/decode failed")
                continue
            }
            if parsed.ok {
                Log.info("slack[\(label)]: probe `\(q)` (\(descr)) → \(parsed.messages?.total ?? 0) match(es)")
            } else {
                Log.info("slack[\(label)]: probe `\(q)` (\(descr)) → error=\(parsed.error ?? "?")")
            }
        }
    }

    // MARK: - User directory

    /// Cached display-name lookup. Used to humanize `<@U…>` mention tokens
    /// and DM partner ids. Falls back to id when nothing better is available.
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

    /// Orchestrates the conversations-API fallback path. Discovers
    /// channels with unread state, expands them to their unread
    /// messages, and returns Match-shaped values for the existing
    /// dedupe + render path. Best-effort throughout — any failure
    /// here is a missed bot alert, not a fetch-killing error, so we
    /// log and keep going rather than throw.
    private func fetchConversationsAPIUnreads(prefs: SlackPrefs, token: String)
        async -> [SearchResp.Match]
    {
        async let domainTask: String? = Self.teamDomain(token: token)

        let conversations = await Self.userConversations(token: token)
        let candidates = Self.conversationCandidates(conversations, prefs: prefs)
        let probed = Array(candidates.prefix(Self.conversationsInfoCap))
        let unreadStatuses = await Self.unreadChannelStatuses(
            candidates: probed, token: token, cap: 8
        )
        let toFetch = Array(unreadStatuses.prefix(Self.conversationsHistoryCap))
        let domain = await domainTask
        Log.info("slack[\(account.label)]: conversations-API probed \(probed.count)/\(candidates.count) channel(s), \(unreadStatuses.count) unread, fetching history for \(toFetch.count)")

        var matches: [SearchResp.Match] = []
        await withTaskGroup(of: [SearchResp.Match].self) { group in
            var next = 0
            let cap = 4
            for (conv, lastRead) in toFetch.prefix(cap) {
                group.addTask {
                    let msgs = await Self.conversationHistory(
                        channelID: conv.id, oldest: lastRead, token: token
                    )
                    return Self.matches(from: msgs, in: conv, domain: domain)
                }
                next += 1
            }
            while let result = await group.next() {
                if next < toFetch.count {
                    let (conv, lastRead) = toFetch[next]
                    group.addTask {
                        let msgs = await Self.conversationHistory(
                            channelID: conv.id, oldest: lastRead, token: token
                        )
                        return Self.matches(from: msgs, in: conv, domain: domain)
                    }
                    next += 1
                }
                matches.append(contentsOf: result)
            }
        }
        if !matches.isEmpty {
            Log.info("slack[\(account.label)]: conversations-API fallback returned \(matches.count) message(s)")
        }
        return matches
    }

    // MARK: - Conversations API fallback (for bot-authored unreads)

    /// search.messages?is:unread is content-indexed; bot/app-authored
    /// messages (PagerDuty, Datadog, Jira, etc.) are silently excluded
    /// even when they're genuinely unread. The conversations API is
    /// read-state-based — `last_read` and `unread_count_display` per
    /// channel — so it catches whatever Slack itself considers unread,
    /// regardless of who authored it. We fan out:
    ///
    ///   1. users.conversations  → channels the user is in
    ///   2. conversations.info   → last_read + unread_count per channel
    ///   3. conversations.history → unread messages from channels with
    ///      unread_count > 0
    ///
    /// Cost: 1-3 (list) + N (info, capped 100) + M (history, capped 30)
    /// + 1 (team.info for permalink construction). Tiers 4 / 3 absorb
    /// it. Channel-level prefs (deny/allow/include flags) are applied
    /// pre-info so we don't pay for channels we'd filter out anyway.
    fileprivate struct Conversation: Decodable {
        let id: String
        let name: String?
        let is_im: Bool?
        let is_mpim: Bool?
        let is_private: Bool?
        let is_archived: Bool?
        let is_member: Bool?
        let user: String?  // partner user id, set on IMs
    }

    fileprivate struct ConversationInfoChannel: Decodable {
        let last_read: String?
        let unread_count_display: Int?
    }

    fileprivate struct HistoryMessage: Decodable {
        let ts: String?
        let user: String?
        let bot_id: String?
        let username: String?
        let text: String?
        let subtype: String?
    }

    /// Maximum candidate channels to probe per fetch via conversations.info.
    /// Sized so even at 100 (cap) calls we stay under Tier 4's 100/min budget
    /// for a single fetch. Heavy-channel users may not see every channel
    /// every refresh, but is:unread already covers the human-authored case.
    fileprivate static let conversationsInfoCap = 100
    /// Maximum unread channels we'll expand to history per fetch. Bounded
    /// independently so a workspace where every channel has unread bot
    /// chatter doesn't blow the Tier 3 budget (50/min).
    fileprivate static let conversationsHistoryCap = 30
    /// Per-channel history page size. 20 is enough to catch bursty alert
    /// streams (PagerDuty fires multiple in rapid succession) without
    /// dredging up old chatter when last_read is recent.
    fileprivate static let conversationsHistoryLimit = 20

    fileprivate static func userConversations(token: String) async -> [Conversation] {
        var all: [Conversation] = []
        var cursor: String? = nil
        repeat {
            var comps = URLComponents(string: "https://slack.com/api/users.conversations")!
            var items: [URLQueryItem] = [
                .init(name: "limit", value: "200"),
                .init(name: "exclude_archived", value: "true"),
                .init(name: "types", value: "public_channel,private_channel,mpim,im"),
            ]
            if let c = cursor { items.append(.init(name: "cursor", value: c)) }
            comps.queryItems = items
            guard let url = comps.url,
                  let (data, _) = try? await slackGet(url, token: token) else { return all }
            struct Resp: Decodable {
                let ok: Bool
                let channels: [Conversation]?
                let response_metadata: Meta?
                struct Meta: Decodable { let next_cursor: String? }
            }
            guard let parsed = try? JSONDecoder().decode(Resp.self, from: data), parsed.ok else { return all }
            all.append(contentsOf: parsed.channels ?? [])
            let next = parsed.response_metadata?.next_cursor ?? ""
            cursor = next.isEmpty ? nil : next
        } while cursor != nil && all.count < 1000
        return all
    }

    fileprivate static func conversationInfo(channelID: String, token: String)
        async -> ConversationInfoChannel?
    {
        var comps = URLComponents(string: "https://slack.com/api/conversations.info")!
        comps.queryItems = [
            .init(name: "channel", value: channelID),
            .init(name: "include_locale", value: "false"),
        ]
        guard let url = comps.url,
              let (data, _) = try? await slackGet(url, token: token) else { return nil }
        struct Resp: Decodable {
            let ok: Bool
            let channel: ConversationInfoChannel?
        }
        guard let parsed = try? JSONDecoder().decode(Resp.self, from: data), parsed.ok else { return nil }
        return parsed.channel
    }

    fileprivate static func conversationHistory(channelID: String, oldest: String, token: String)
        async -> [HistoryMessage]
    {
        var comps = URLComponents(string: "https://slack.com/api/conversations.history")!
        comps.queryItems = [
            .init(name: "channel", value: channelID),
            .init(name: "oldest", value: oldest),
            .init(name: "limit", value: String(conversationsHistoryLimit)),
            .init(name: "inclusive", value: "false"),
        ]
        guard let url = comps.url,
              let (data, _) = try? await slackGet(url, token: token) else { return [] }
        struct Resp: Decodable {
            let ok: Bool
            let messages: [HistoryMessage]?
        }
        guard let parsed = try? JSONDecoder().decode(Resp.self, from: data), parsed.ok else { return [] }
        return parsed.messages ?? []
    }

    /// One call per fetch to discover the workspace domain — needed to
    /// construct permalinks for messages from conversations.history (which
    /// doesn't return them, unlike search.messages). Falls back to a
    /// best-effort `slack.com/archives/...` form when team.info is
    /// unavailable; that URL still resolves correctly via Slack's
    /// general redirect.
    fileprivate static func teamDomain(token: String) async -> String? {
        guard let url = URL(string: "https://slack.com/api/team.info"),
              let (data, _) = try? await slackGet(url, token: token) else { return nil }
        struct Resp: Decodable {
            let ok: Bool
            let team: Team?
            struct Team: Decodable { let domain: String? }
        }
        let parsed = try? JSONDecoder().decode(Resp.self, from: data)
        return (parsed?.ok == true) ? parsed?.team?.domain : nil
    }

    /// Slack permalinks: `https://<domain>.slack.com/archives/<CHAN>/p<TS>`
    /// where TS has the dot stripped. When the team domain isn't known
    /// we fall back to the generic `slack.com/archives/...` form — Slack
    /// redirects this for authenticated users.
    fileprivate static func permalinkFor(channelID: String, ts: String, domain: String?) -> String {
        let tsCompact = ts.replacingOccurrences(of: ".", with: "")
        if let d = domain, !d.isEmpty {
            return "https://\(d).slack.com/archives/\(channelID)/p\(tsCompact)"
        }
        return "https://slack.com/archives/\(channelID)/p\(tsCompact)"
    }

    /// Fan-out wrapper: probe every channel in `candidates` for unread
    /// state via conversations.info, parallelizing with `cap` requests
    /// in flight at once. Returns the subset whose unread_count_display
    /// is positive, paired with their last_read ts.
    fileprivate static func unreadChannelStatuses(candidates: [Conversation],
                                                   token: String,
                                                   cap: Int) async -> [(Conversation, String)] {
        var out: [(Conversation, String)] = []
        await withTaskGroup(of: (Conversation, String)?.self) { group in
            var next = 0
            for c in candidates.prefix(cap) {
                group.addTask { await Self.probeUnread(c: c, token: token) }
                next += 1
            }
            while let result = await group.next() {
                if next < candidates.count {
                    let c = candidates[next]
                    group.addTask { await Self.probeUnread(c: c, token: token) }
                    next += 1
                }
                if let r = result { out.append(r) }
            }
        }
        return out
    }

    private static func probeUnread(c: Conversation, token: String) async -> (Conversation, String)? {
        guard let info = await conversationInfo(channelID: c.id, token: token) else { return nil }
        guard (info.unread_count_display ?? 0) > 0 else { return nil }
        guard let last = info.last_read, !last.isEmpty else { return nil }
        return (c, last)
    }

    /// Filter the user's joined-conversation list down to candidates we'd
    /// actually surface in the digest, applying the same prefs (deny /
    /// allow / DM-MPIM-channel includes) the render path applies after.
    /// Doing it pre-info-call saves API budget on channels we'd discard.
    fileprivate static func conversationCandidates(_ all: [Conversation], prefs: SlackPrefs)
        -> [Conversation]
    {
        let allow = prefs.allowlist
        let deny = prefs.denylist
        return all.compactMap { c in
            if c.is_archived == true { return nil }
            if c.is_member == false { return nil }
            let chName = (c.name ?? "").lowercased()
            if !chName.isEmpty && deny.contains(chName) { return nil }
            let inAllowlist = !chName.isEmpty && allow.contains(chName)
            if inAllowlist { return c }
            let isIM = c.is_im == true
            let isMPIM = c.is_mpim == true
            let isChannel = !isIM && !isMPIM
            if isIM, !prefs.includeDMs { return nil }
            if isMPIM, !prefs.includeMPIMs { return nil }
            if isChannel {
                let channelOK = prefs.includeStarred || prefs.channelMode != .off
                if !channelOK { return nil }
            }
            return c
        }
    }

    /// History → Match conversion. Drops channel-join/leave/topic-change
    /// noise (subtype is set for those), and skips messages with neither
    /// a user id nor a bot id (rare malformed entries).
    fileprivate static func matches(from history: [HistoryMessage],
                                    in channel: Conversation,
                                    domain: String?) -> [SearchResp.Match] {
        let chShape = SearchResp.Match.Channel(
            id: channel.id, name: channel.name,
            is_im: channel.is_im, is_mpim: channel.is_mpim,
            is_private: channel.is_private
        )
        return history.compactMap { m -> SearchResp.Match? in
            guard let ts = m.ts else { return nil }
            // Skip system noise: joins, leaves, topic changes, etc.
            // bot_message subtype is what we explicitly DO want.
            if let st = m.subtype, st != "bot_message", st != "thread_broadcast" {
                return nil
            }
            // Need *something* identifying the sender, else the row is empty.
            if (m.user ?? "").isEmpty && (m.bot_id ?? "").isEmpty && (m.username ?? "").isEmpty {
                return nil
            }
            return SearchResp.Match(
                channel: chShape,
                user: m.user,
                username: m.username,
                text: m.text,
                ts: ts,
                permalink: permalinkFor(channelID: channel.id, ts: ts, domain: domain)
            )
        }
    }

    // MARK: - Helpers

    /// Slack messages use `<@U123>`, `<#C123|name>`, and `<!here>` tokens.
    /// The triage LLM doesn't know those — translate to human form, and mark
    /// the signed-in user as `@me` so the triage rubric's @mention boost fires.
    static func rewriteEntities(_ text: String, users: [String: String], selfID: String?) -> String {
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

    /// Wrap URLSession with Slack's OAuth bearer header.
    private static func slackGet(_ url: URL, token: String) async throws -> (Data, URLResponse) {
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return try await URLSession.shared.data(for: req)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

