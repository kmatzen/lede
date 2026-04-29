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
    static let userScopes = "channels:history,groups:history,im:history,mpim:history,users:read,channels:read,groups:read,im:read,mpim:read"
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
        SlackStarredCache.clear(teamID: accountID)
        // Pre-v0.1.14 wrote a persistent autoDiscoveryInitiated flag we no
        // longer read. Clean it up on signOut so an old workspace that had
        // it set doesn't carry stale UserDefaults if the user reconnects.
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
/// The defaults aim at "high-signal, low API cost": DMs, group DMs, and
/// channels the user has explicitly starred. Member channels are off by
/// default because including them requires a `conversations.info` call per
/// channel, which is expensive on workspaces with hundreds of channels.
struct SlackPrefs {
    let teamID: String

    /// What to do with public/private channels the user is a member of.
    enum ChannelMode: String {
        /// Don't include member channels at all (still respects allowlist + starred).
        case off
        /// Only include unread mentions / thread replies (uses `unread_count_display`).
        case mentions
        /// Include any unread message (uses `unread_count`).
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
    /// Always check channels marked starred in the user's sidebar, regardless
    /// of the channel mode below.
    var includeStarred: Bool {
        get { boolDefault("includeStarred", default: true) }
        nonmutating set { setBool("includeStarred", newValue) }
    }
    var channelMode: ChannelMode {
        get {
            let raw = UserDefaults.standard.string(forKey: key("channelMode")) ?? ""
            return ChannelMode(rawValue: raw) ?? .off
        }
        nonmutating set { UserDefaults.standard.set(newValue.rawValue, forKey: key("channelMode")) }
    }

    /// Comma-separated list, raw form so the UI can bind to it verbatim.
    /// Parsed into `allowlist` / `denylist` (lowercased, stripped of leading `#`).
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
    /// Internal so tests can pin the parsing rules (strip `#`, lowercase,
    /// trim whitespace, split on commas, drop empties) without going through
    /// UserDefaults round-trips.
    static func parseList(_ raw: String) -> Set<String> {
        Set(raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .map { $0.hasPrefix("#") ? String($0.dropFirst()) : $0 }
            .filter { !$0.isEmpty })
    }
}

// MARK: - is_starred cache

/// Per-workspace cache of `is_starred` flags. Star membership rarely changes,
/// so caching it lets us avoid hitting `conversations.info` on every channel
/// every refresh just to ask "is this still starred?".
///
/// Entries older than `freshTTL` are still consulted (so we treat a stale-but-
/// previously-starred channel as still starred for one refresh) but flagged
/// for re-fetch when the API budget allows.
struct SlackStarredCache: Codable {
    /// Bumped when the cache schema or recording rules change. v0.1.x≤15
    /// pollutes the cache with IM/MPIM entries (because `fetchInfos`
    /// recorded every probe regardless of conversation type), which breaks
    /// the "is this cache empty?" gate that controls auto-discovery.
    /// v2 keeps only channel entries; older caches get discarded on load.
    static let currentVersion = 2
    var version: Int = currentVersion
    var entries: [String: Entry] = [:]
    struct Entry: Codable {
        var isStarred: Bool
        var fetchedAt: Date
    }

    static let freshTTL: TimeInterval = 60 * 60   // 1 hour

    static func load(teamID: String) -> SlackStarredCache {
        guard let data = UserDefaults.standard.data(forKey: key(teamID)),
              let cache = try? JSONDecoder().decode(SlackStarredCache.self, from: data),
              cache.version == currentVersion
        else { return SlackStarredCache() }
        return cache
    }

    func save(teamID: String) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.key(teamID))
    }

    static func clear(teamID: String) {
        UserDefaults.standard.removeObject(forKey: key(teamID))
    }

    private static func key(_ teamID: String) -> String {
        "lede.slack.\(teamID).starredCache"
    }

    func isStarred(_ channelID: String) -> Bool? {
        entries[channelID]?.isStarred
    }
    func isFresh(_ channelID: String, now: Date = Date()) -> Bool {
        guard let e = entries[channelID] else { return false }
        return now.timeIntervalSince(e.fetchedAt) < Self.freshTTL
    }
    mutating func record(_ channelID: String, isStarred: Bool, at: Date = Date()) {
        entries[channelID] = Entry(isStarred: isStarred, fetchedAt: at)
    }
}

// MARK: - Source

struct SlackSource: NotificationSource {
    let account: Account
    let source: Source = .slack

    var isConfigured: Bool {
        Keychain.get(Keychain.Key.slackAccess(account.id)) != nil
    }

    /// Hard cap on `conversations.info` calls per refresh. Slack rates that
    /// method at Tier 3 (~50/min); we throttle to ~50/min and cap absolute
    /// volume so a workspace with thousands of channels can't stall us forever.
    /// 200 is comfortably more than the bounded candidate set should ever be
    /// in default config (DMs+MPIMs+cached starred); only `channelMode == .all`
    /// in a giant workspace approaches it.
    private static let infoCallBudget = 200

    /// Sleep between successive `conversations.info` calls. ~50/min → at the
    /// Tier 3 limit but Slack honors Retry-After if we trip 429.
    private static let infoCallSpacing: TimeInterval = 1.2

    func fetch() async throws -> [RawItem] {
        guard let token = Keychain.get(Keychain.Key.slackAccess(account.id)) else { return [] }
        let userID = Keychain.get(Keychain.Key.slackUserID(account.id))
        let teamID = account.id
        let prefs = SlackPrefs(teamID: teamID)

        // Diagnostic: confirm token identity + scopes once per refresh. Cheap
        // (Tier 1, 100/min) and removes a class of "is the token broken?"
        // hypotheses when reads come back empty.
        await Self.logAuthTest(token: token, label: account.label)

        // Cheap listing of every conversation the user can see. Type pre-filter
        // happens here so private/public channels don't pollute the candidate
        // set when the user has channelMode == .off and no allowlist.
        let convos = try await Self.allConversations(token: token)
        var cache = SlackStarredCache.load(teamID: teamID)
        // Cache state diagnostic — tells us whether discovery has captured any
        // starred channels yet, and whether old polluted caches were correctly
        // cleared by the version bump.
        let cacheStarred = cache.entries.values.filter { $0.isStarred }.count
        Log.info("slack[\(account.label)] cache state: \(cache.entries.count) entries, \(cacheStarred) starred")

        // Diagnostic: dump full raw conversations.info response body for one
        // IM, one MPIM, one channel so we can see exactly what fields Slack
        // populates vs. omits. The same channels get re-probed by the regular
        // fetch loop below — three duplicate calls per refresh is fine on
        // Tier 3 and worth it while we're still chasing the empty-state bug.
        await Self.logTypeSamples(token: token, label: account.label, convos: convos)

        // First refresh after connecting a workspace: kick off starred
        // discovery in the background so the user doesn't have to know to
        // click the Settings button. Idempotent across launches via a
        // UserDefaults flag — discovery walks ~50 channels/min, so we don't
        // want to re-run it unnecessarily.
        Self.maybeAutoDiscoverStarred(account: account, prefs: prefs, cache: cache)

        let candidates = Self.candidates(from: convos, prefs: prefs, cache: cache)
        // Type breakdown so we can sanity-check pre-filter math against the
        // raw API shape (e.g. "are 880 of those candidates really MPIMs, or
        // are channels slipping through?").
        let imCount = convos.filter { $0.is_im == true }.count
        let mpimCount = convos.filter { $0.is_mpim == true }.count
        let channelCount = convos.count - imCount - mpimCount
        Log.info("slack[\(account.label)]: \(convos.count) conversation(s) [\(imCount) IM, \(mpimCount) MPIM, \(channelCount) channel], \(candidates.count) candidate(s) after pre-filter")

        // Fetch authoritative unread state + is_starred for each candidate.
        // Rate-limited and budgeted; surplus candidates are dropped this refresh
        // and will be picked up next cycle (the cache gradually fills in).
        let infos = await Self.fetchInfos(
            for: candidates, token: token, prefs: prefs, cache: &cache
        )
        cache.save(teamID: teamID)

        // End-of-refresh breakdown: how many of the probed conversations had
        // any unread, mentions, or starred state? Tells us whether the API
        // is reporting *anything* — distinguishes "token has no permission"
        // from "the user genuinely had no unreads in the probed slice."
        let probedTotal = infos.count
        let withUnread = infos.filter { $0.unreadCount > 0 }.count
        let withMentions = infos.filter { $0.unreadCountDisplay > 0 }.count
        let starred = infos.filter { $0.isStarred }.count
        Log.info("slack[\(account.label)]: probed \(probedTotal) — \(withUnread) had unread, \(withMentions) had mentions, \(starred) starred")

        let surviving = infos.filter { Self.shouldSurface($0, prefs: prefs) }
        Log.info("slack[\(account.label)]: \(surviving.count) unread conversation(s) after info fetch")

        let users = await Self.userNameCache(token: token)
        let acct = account
        return try await withThrowingTaskGroup(of: RawItem?.self) { group in
            for info in surviving {
                group.addTask {
                    try await Self.buildItem(info: info, token: token, users: users,
                                             userID: userID, teamID: teamID, account: acct)
                }
            }
            var out: [RawItem] = []
            for try await item in group { if let item { out.append(item) } }
            return out
        }
    }

    // MARK: - Conversations (cheap listing)

    /// Trimmed shape of what `users.conversations` returns. We deliberately
    /// don't decode `unread_count_display` here — that field is unreliable on
    /// this endpoint (often nil), which is the bug that motivated this rewrite.
    /// Authoritative unread state comes from `conversations.info` instead.
    /// Internal so tests can construct Conversation fixtures and exercise the
    /// candidate / surfacing logic without hitting Slack.
    struct Conversation: Decodable {
        let id: String
        let name: String?
        let is_im: Bool?
        let is_mpim: Bool?
        let is_channel: Bool?
        let is_private: Bool?
        let is_member: Bool?
        let user: String?           // DM partner user id
        /// True when the user has this DM/MPIM open in their sidebar. Slack
        /// returns every IM the user has ever participated in from
        /// `users.conversations`, including ones closed years ago — `is_open`
        /// is the only signal that distinguishes a live DM from a dead one.
        /// Always true for channels you're a member of, so we only consult it
        /// for IMs/MPIMs.
        let is_open: Bool?
    }

    /// Paginate through every conversation the user is a member of (or sees,
    /// for DMs). Capped so a very large workspace doesn't lock us up.
    private static func allConversations(token: String) async throws -> [Conversation] {
        var all: [Conversation] = []
        var cursor: String? = nil
        let maxTotal = 2000
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

    // MARK: - Pre-filter

    /// Decide which conversations are worth a `conversations.info` round-trip
    /// based on prefs alone (no API). Order of precedence:
    ///   1. Denylist (by name) wins, full stop.
    ///   2. Allowlist (by name) forces inclusion.
    ///   3. Type toggles (DMs / MPIMs).
    ///   4. Channel mode + cached starred status for member channels.
    /// Hard cap on IMs that survive the pre-filter. `users.conversations`
    /// returns every IM the user has ever DM'd (often 1k+ on a busy workspace);
    /// without this cap they'd consume the entire conversations.info budget
    /// per refresh and never leave room for MPIMs / starred / channels. We
    /// keep the first N as Slack returns them — order is undocumented but
    /// observed to be roughly recency/activity-weighted in practice.
    static let imCandidateCap = 150

    static func candidates(from convos: [Conversation],
                           prefs: SlackPrefs,
                           cache: SlackStarredCache) -> [Conversation] {
        let allow = prefs.allowlist
        let deny = prefs.denylist
        let mode = prefs.channelMode

        let filtered = convos.filter { c in
            let name = (c.name ?? "").lowercased()
            if !name.isEmpty && deny.contains(name) { return false }
            if !name.isEmpty && allow.contains(name) { return true }

            // IMs/MPIMs gate purely on the pref toggles. We previously also
            // required `is_open == true` to drop dormant DMs, but that field
            // isn't actually returned by `users.conversations` — only by
            // `conversations.info` — so the check evaluated false for every
            // IM and pre-filtered the entire candidate set away. The IM cap
            // applied below is what now bounds candidate volume.
            if c.is_im == true { return prefs.includeDMs }
            if c.is_mpim == true { return prefs.includeMPIMs }

            // Public / private channel from here down. We previously gated
            // this on `c.is_member == true`, but that field — like `is_open`
            // — isn't reliably populated by `users.conversations`. Since the
            // endpoint only returns conversations the user is a member of by
            // contract, we just trust it and drop the explicit check.
            if mode != .off { return true }
            // Starred channels: only ones the cache *already knows* are starred.
            // First-run discovery is a separate, explicit one-shot via
            // `discoverStarred(account:)` — we never bulk-probe unknown channels
            // during a regular refresh.
            if prefs.includeStarred && cache.isStarred(c.id) == true { return true }
            return false
        }
        // Apply the IM cap. Splitting then concatenating preserves Slack's
        // original ordering for both halves so the downstream priority sort
        // stays stable.
        let allowedIMs = filtered.filter { $0.is_im == true }
        let cappedIMs = Array(allowedIMs.prefix(imCandidateCap))
        let nonIMs = filtered.filter { $0.is_im != true }
        return cappedIMs + nonIMs
    }

    // MARK: - conversations.info (authoritative state)

    /// Authoritative per-channel state. Fields here come from `conversations.info`
    /// which (unlike `users.conversations`) reliably populates unread counts.
    /// Internal so tests can synthesize `ConversationInfo` fixtures for
    /// `shouldSurface` without round-tripping through Slack's API.
    struct ConversationInfo {
        let id: String
        let name: String?
        let isIM: Bool
        let isMPIM: Bool
        let dmUser: String?
        let isStarred: Bool
        let unreadCount: Int            // every unread message
        let unreadCountDisplay: Int     // mentions / threads / DMs
        let lastReadTS: String?
    }

    /// Run `conversations.info` against each candidate, sequentially, with
    /// rate-limit pacing. Honors a hard budget so we don't get stuck on
    /// pathological workspaces. Updates the starred cache in place.
    private static func fetchInfos(for candidates: [Conversation],
                                   token: String,
                                   prefs: SlackPrefs,
                                   cache: inout SlackStarredCache) async -> [ConversationInfo] {
        // Prioritize: DMs first, then user-curated channels (allowlist +
        // known-starred), then MPIMs, then everything else. Earlier versions
        // had MPIMs at priority 1, but workspaces with hundreds of stale group
        // DMs (e.g. 883 MPIMs on the test workspace) were starving out the
        // 13 starred channels that the user actually cares about. Snapshotted
        // into a Set so the closure doesn't capture the inout cache.
        let allow = prefs.allowlist
        let knownStarred: Set<String> = Set(cache.entries.compactMap { $0.value.isStarred ? $0.key : nil })
        let priority: (Conversation) -> Int = { c in
            if c.is_im == true { return 0 }
            let name = (c.name ?? "").lowercased()
            if !name.isEmpty && allow.contains(name) { return 1 }
            if knownStarred.contains(c.id) { return 2 }
            if c.is_mpim == true { return 3 }
            return 4
        }
        let ordered = candidates.sorted { priority($0) < priority($1) }

        var out: [ConversationInfo] = []
        var calls = 0
        for c in ordered {
            if calls >= infoCallBudget {
                Log.warn("slack: conversations.info budget (\(infoCallBudget)) hit; \(candidates.count - calls) candidate(s) deferred to next refresh")
                break
            }
            if calls > 0 {
                try? await Task.sleep(nanoseconds: UInt64(infoCallSpacing * 1_000_000_000))
            }
            // Log the first response per refresh in detail so we can verify
            // Slack's actual return shape against our assumptions (is_starred,
            // unread_count, unread_count_display, last_read populated as docs
            // claim). After the first call, we trust the parser.
            let logFull = (calls == 0)
            calls += 1
            if let info = await Self.conversationInfo(channelID: c.id, token: token,
                                                      fallback: c, logFull: logFull) {
                // Only channels go into the starred cache. Recording IMs/MPIMs
                // here was the v0.1.10–15 cache pollution bug: a non-empty
                // cache full of non-channel entries silenced the auto-discovery
                // gate, so channels never got their is_starred captured and
                // starred-channel unreads never surfaced.
                let isChannel = (c.is_im != true && c.is_mpim != true)
                if isChannel {
                    cache.record(c.id, isStarred: info.isStarred)
                }
                out.append(info)
            }
        }
        return out
    }

    /// Single `conversations.info` round-trip. Returns nil on transient errors
    /// so one bad channel doesn't take down the whole refresh. `logFull=true`
    /// emits a one-time-per-refresh diagnostic at INFO level so we can verify
    /// Slack's actual response shape in the field.
    private static func conversationInfo(channelID: String,
                                         token: String,
                                         fallback: Conversation,
                                         logFull: Bool = false) async -> ConversationInfo? {
        var comps = URLComponents(string: "https://slack.com/api/conversations.info")!
        comps.queryItems = [
            .init(name: "channel", value: channelID),
            .init(name: "include_num_members", value: "false"),
        ]
        guard let (data, resp) = try? await slackGet(comps.url!, token: token) else { return nil }
        if let http = resp as? HTTPURLResponse, http.statusCode == 429 {
            let wait = Int(http.value(forHTTPHeaderField: "Retry-After") ?? "1") ?? 1
            try? await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000_000)
            return nil
        }
        struct Resp: Decodable {
            let ok: Bool
            let error: String?
            let channel: Channel?
            struct Channel: Decodable {
                let id: String
                let name: String?
                let is_im: Bool?
                let is_mpim: Bool?
                let user: String?
                let is_starred: Bool?
                let unread_count: Int?
                let unread_count_display: Int?
                let last_read: String?
            }
        }
        guard let parsed = try? JSONDecoder().decode(Resp.self, from: data),
              parsed.ok, let ch = parsed.channel else {
            if logFull {
                let raw = String(data: data, encoding: .utf8) ?? ""
                Log.warn("slack: conversations.info first-call returned non-OK or unparseable: \(raw.prefix(400))")
            }
            return nil
        }
        if logFull {
            Log.info("slack: conversations.info sample channel=\(ch.id) name=\(ch.name ?? "(none)") is_starred=\(String(describing: ch.is_starred)) unread_count=\(String(describing: ch.unread_count)) unread_count_display=\(String(describing: ch.unread_count_display)) last_read=\(ch.last_read ?? "(none)")")
        }
        return ConversationInfo(
            id: ch.id,
            name: ch.name ?? fallback.name,
            isIM: ch.is_im ?? (fallback.is_im ?? false),
            isMPIM: ch.is_mpim ?? (fallback.is_mpim ?? false),
            dmUser: ch.user ?? fallback.user,
            isStarred: ch.is_starred ?? false,
            unreadCount: ch.unread_count ?? 0,
            unreadCountDisplay: ch.unread_count_display ?? 0,
            lastReadTS: ch.last_read
        )
    }

    // MARK: - Starred discovery

    /// Process-wide mutex over starred discovery. Prevents concurrent walks
    /// of the same workspace — auto-discovery firing while the user has the
    /// "Find starred channels" button mid-run, or back-to-back refreshes
    /// before the first batch saves to cache.
    actor DiscoveryGuard {
        static let shared = DiscoveryGuard()
        private var active: Set<String> = []

        func acquire(_ teamID: String) -> Bool {
            if active.contains(teamID) { return false }
            active.insert(teamID)
            return true
        }
        func release(_ teamID: String) {
            active.remove(teamID)
        }
    }

    /// Fire-and-forget `discoverStarred` when the cache is empty + the user
    /// has includeStarred on. Earlier versions also gated on a persistent
    /// "have we ever auto-fired for this workspace?" UserDefaults flag, but
    /// that interacted poorly with bug-fix releases — a buggy v0.1.12 set the
    /// flag and v0.1.13's correct code couldn't re-fire. The DiscoveryGuard
    /// already covers concurrent fires within a session, and the cache fills
    /// incrementally (saved every 25 channels) so it flips off the gate
    /// shortly after discovery actually starts.
    static func maybeAutoDiscoverStarred(account: Account,
                                         prefs: SlackPrefs,
                                         cache: SlackStarredCache) {
        guard prefs.includeStarred, cache.entries.isEmpty else { return }
        let acct = account
        Log.info("slack[\(acct.label)]: auto-discovering starred channels in background")
        Task.detached {
            await SlackSource.discoverStarred(account: acct) { _, _ in }
        }
    }

    // MARK: - Starred discovery (one-shot, opt-in)

    /// Walk every member channel that isn't already in the starred cache and
    /// run `conversations.info` to learn its `is_starred` flag. The cache is
    /// then consulted on every subsequent refresh — so this only needs to run
    /// once after connecting a workspace, plus occasionally when the user
    /// stars new channels. Rate-limited to ~50/min and saves the cache every
    /// 25 channels so a mid-walk crash doesn't lose progress.
    static func discoverStarred(account: Account,
                                onProgress: @escaping @Sendable (Int, Int) -> Void) async {
        // Mutex against duplicate concurrent walks (auto + manual button,
        // overlapping refreshes during the first 30s before the first
        // 25-channel save flips cache.entries.isEmpty off, etc.).
        guard await DiscoveryGuard.shared.acquire(account.id) else {
            Log.info("slack discover[\(account.label)]: already running, skipping")
            return
        }
        defer { Task.detached { await DiscoveryGuard.shared.release(account.id) } }
        guard let token = Keychain.get(Keychain.Key.slackAccess(account.id)) else { return }
        let teamID = account.id
        var cache = SlackStarredCache.load(teamID: teamID)

        let convos: [Conversation]
        do { convos = try await allConversations(token: token) }
        catch {
            Log.error("slack discover: users.conversations failed — \(error.localizedDescription)")
            return
        }

        let toProbe = convos.filter { c in
            // Channels (everything that isn't an IM or MPIM) we haven't probed
            // before. We don't check `is_member` because users.conversations
            // doesn't reliably return that field — and only returns conversations
            // the user is part of in the first place, by API contract.
            let isChannel = (c.is_im != true && c.is_mpim != true)
            return isChannel && cache.entries[c.id] == nil
        }
        let total = toProbe.count
        Log.info("slack discover[\(account.label)]: \(total) channel(s) to probe")
        onProgress(0, total)

        var done = 0
        var foundStarred = 0
        for c in toProbe {
            if done > 0 {
                try? await Task.sleep(nanoseconds: UInt64(infoCallSpacing * 1_000_000_000))
            }
            if let info = await conversationInfo(channelID: c.id, token: token, fallback: c) {
                cache.record(c.id, isStarred: info.isStarred)
                if info.isStarred { foundStarred += 1 }
            }
            done += 1
            onProgress(done, total)
            if done % 25 == 0 {
                cache.save(teamID: teamID)
                Log.info("slack discover[\(account.label)]: \(done)/\(total) probed (\(foundStarred) starred so far)")
            }
            if Task.isCancelled { break }
        }
        cache.save(teamID: teamID)
        Log.info("slack discover[\(account.label)]: probed \(done)/\(total), \(foundStarred) starred")
    }

    // MARK: - Final filter

    /// Decide whether a channel's authoritative state warrants surfacing as a
    /// notification. Mirrors the pre-filter precedence so allowlist/starred/type
    /// each trigger inclusion, but only when there's *actual* unread activity
    /// — we never surface a channel that's already been read.
    static func shouldSurface(_ info: ConversationInfo, prefs: SlackPrefs) -> Bool {
        let name = (info.name ?? "").lowercased()
        if !name.isEmpty && prefs.denylist.contains(name) { return false }

        // Allowlist & starred: any unread message qualifies, since the user
        // explicitly said "watch this channel."
        if !name.isEmpty && prefs.allowlist.contains(name) {
            return info.unreadCount > 0
        }
        if prefs.includeStarred && info.isStarred {
            return info.unreadCount > 0
        }

        // DMs / MPIMs: any unread message; `unread_count_display` for DMs
        // matches `unread_count` so either works, but unreadCount is simpler.
        if info.isIM { return prefs.includeDMs && info.unreadCount > 0 }
        if info.isMPIM { return prefs.includeMPIMs && info.unreadCount > 0 }

        // Member channels: gated on the channel mode.
        switch prefs.channelMode {
        case .off:       return false
        case .mentions:  return info.unreadCountDisplay > 0
        case .all:       return info.unreadCount > 0
        }
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

    private static func buildItem(info: ConversationInfo,
                                  token: String,
                                  users: [String: String],
                                  userID: String?,
                                  teamID: String,
                                  account: Account) async throws -> RawItem? {
        var comps = URLComponents(string: "https://slack.com/api/conversations.history")!
        comps.queryItems = [
            .init(name: "channel", value: info.id),
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
            if info.isIM, let u = info.dmUser { return "DM: \(users[u] ?? u)" }
            if info.isMPIM { return "Group DM" }
            if let n = info.name { return "#\(n)" }
            return info.id
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
        let url: URL? = {
            var parts: [URLQueryItem] = [
                .init(name: "team", value: teamID),
                .init(name: "id", value: info.id),
            ]
            if let ts = msg.ts { parts.append(.init(name: "message", value: ts)) }
            var c = URLComponents()
            c.scheme = "slack"
            c.host = "channel"
            c.queryItems = parts
            return c.url
        }()

        return RawItem(
            id: "\(info.id):\(msg.ts ?? "")",
            source: .slack,
            accountID: account.id,
            accountLabel: account.label,
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

    // MARK: - Diagnostic logging

    /// One-shot per refresh: log full `auth.test` response so we can verify
    /// the token's user_id, team_id, scopes, and whether Slack thinks the
    /// session is healthy. Token itself is never logged (only sent in
    /// Authorization header by `slackGet`).
    private static func logAuthTest(token: String, label: String) async {
        let url = URL(string: "https://slack.com/api/auth.test")!
        do {
            let (data, _) = try await slackGet(url, token: token)
            let body = String(data: data, encoding: .utf8) ?? ""
            Log.info("slack[\(label)] auth.test: \(body.prefix(800))")
        } catch {
            Log.warn("slack[\(label)] auth.test failed: \(error.localizedDescription)")
        }
    }

    /// Probe one IM, one MPIM, one channel and dump the raw `conversations.info`
    /// response body. Lets us see exactly what Slack returns per type vs. what
    /// our parser expects — critical when state fields come back as zero/null
    /// across the board and we don't yet know if it's the API or our decode.
    private static func logTypeSamples(token: String, label: String, convos: [Conversation]) async {
        let firstIM = convos.first(where: { $0.is_im == true })
        let firstMPIM = convos.first(where: { $0.is_mpim == true })
        let firstChannel = convos.first(where: { $0.is_im != true && $0.is_mpim != true })
        for (kind, c) in [("im", firstIM), ("mpim", firstMPIM), ("channel", firstChannel)] {
            guard let c else { continue }
            await logRawInfo(token: token, label: label, kind: kind, channelID: c.id)
        }
    }

    /// Single raw `conversations.info` dump used by the type-sample probes.
    /// Truncated to 1500 chars so a verbose channel doesn't blow up the log.
    private static func logRawInfo(token: String, label: String, kind: String, channelID: String) async {
        var comps = URLComponents(string: "https://slack.com/api/conversations.info")!
        comps.queryItems = [
            .init(name: "channel", value: channelID),
            .init(name: "include_num_members", value: "false"),
        ]
        do {
            let (data, _) = try await slackGet(comps.url!, token: token)
            let body = String(data: data, encoding: .utf8) ?? ""
            Log.info("slack[\(label)] \(kind)-sample raw: \(body.prefix(1500))")
        } catch {
            Log.warn("slack[\(label)] \(kind)-sample failed: \(error.localizedDescription)")
        }
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
