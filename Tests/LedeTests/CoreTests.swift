import XCTest
@testable import Lede

final class CoreTests: XCTestCase {

    // MARK: contentHash

    func testContentHashIsDeterministic() {
        let a = RawItem(
            id: "1", source: .github, accountID: nil, accountLabel: nil,
            title: "PR review", sender: "alice", snippet: "ready for review",
            url: nil, receivedAt: Date(timeIntervalSince1970: 0), isUnread: true
        )
        let b = a
        XCTAssertEqual(a.contentHash, b.contentHash)
    }

    func testContentHashChangesWithSemanticFields() {
        let base = RawItem(
            id: "1", source: .github, accountID: nil, accountLabel: nil,
            title: "PR review", sender: "alice", snippet: "ready",
            url: nil, receivedAt: Date(), isUnread: true
        )
        let titleChanged = RawItem(
            id: base.id, source: base.source, accountID: base.accountID, accountLabel: base.accountLabel,
            title: "PR REVIEW (urgent)", sender: base.sender, snippet: base.snippet,
            url: base.url, receivedAt: base.receivedAt, isUnread: base.isUnread
        )
        XCTAssertNotEqual(base.contentHash, titleChanged.contentHash)
    }

    func testContentHashIgnoresReceivedAtAndUnread() {
        // Only id/source/accountID/title/sender/snippet feed the hash.
        // Re-fetching the same message at a different moment, or the user
        // reading it elsewhere, shouldn't invalidate its triage cache entry.
        let a = RawItem(id: "1", source: .gmail, accountID: nil, accountLabel: nil,
                        title: "t", sender: "s", snippet: "x",
                        url: nil, receivedAt: Date(timeIntervalSince1970: 0), isUnread: true)
        let b = RawItem(id: "1", source: .gmail, accountID: nil, accountLabel: nil,
                        title: "t", sender: "s", snippet: "x",
                        url: nil, receivedAt: Date(timeIntervalSince1970: 9999), isUnread: false)
        XCTAssertEqual(a.contentHash, b.contentHash)
    }

    func testContentHashSplitsByAccount() {
        // Same message id, different accounts → distinct hashes so two
        // accounts' identical notifications stay distinguishable in the digest.
        let a = RawItem(id: "1", source: .gmail, accountID: "kev@personal.com", accountLabel: "kev@personal.com",
                        title: "t", sender: "s", snippet: "x",
                        url: nil, receivedAt: Date(), isUnread: true)
        let b = RawItem(id: "1", source: .gmail, accountID: "kev@work.com", accountLabel: "kev@work.com",
                        title: "t", sender: "s", snippet: "x",
                        url: nil, receivedAt: Date(), isUnread: true)
        XCTAssertNotEqual(a.contentHash, b.contentHash)
    }

    // MARK: From-header parsing

    func testParseFromHeaderDisplayName() {
        XCTAssertEqual(GmailSource.parseFromHeader("\"Jane Doe\" <jane@example.com>"), "Jane Doe")
    }

    func testParseFromHeaderUnquoted() {
        XCTAssertEqual(GmailSource.parseFromHeader("Jane Doe <jane@example.com>"), "Jane Doe")
    }

    func testParseFromHeaderEmailOnly() {
        XCTAssertEqual(GmailSource.parseFromHeader("<jane@example.com>"), "jane@example.com")
    }

    func testParseFromHeaderBareAddress() {
        XCTAssertEqual(GmailSource.parseFromHeader("jane@example.com"), "jane@example.com")
    }

    func testParseFromHeaderEmpty() {
        XCTAssertNil(GmailSource.parseFromHeader(""))
        XCTAssertNil(GmailSource.parseFromHeader(nil))
    }

    // MARK: Form encoding (verified against JS URLSearchParams)

    func testFormEncodeMatchesURLSearchParams() {
        // Reserved chars: : / @ should be percent-encoded; spaces become +
        let out = ClaudeOAuth.formEncode([
            ("scope", "user:profile user:inference"),
            ("redirect", "http://localhost:9000/callback"),
            ("login_hint", "test@example.com"),
        ])
        XCTAssertEqual(out,
            "scope=user%3Aprofile+user%3Ainference&redirect=http%3A%2F%2Flocalhost%3A9000%2Fcallback&login_hint=test%40example.com"
        )
    }

    // MARK: ItemTriage Codable

    func testItemTriageRoundtrip() throws {
        let original = ItemTriage(
            contentHash: "abc123", score: 7, summary: "review needed",
            reason: "blocking PR", createdAt: Date(timeIntervalSince1970: 1700000000)
        )
        let data = try JSONEncoder.iso.encode(original)
        let decoded = try JSONDecoder.iso.decode(ItemTriage.self, from: data)
        XCTAssertEqual(decoded.contentHash, original.contentHash)
        XCTAssertEqual(decoded.score, original.score)
        XCTAssertEqual(decoded.summary, original.summary)
        XCTAssertEqual(decoded.reason, original.reason)
        XCTAssertEqual(decoded.createdAt.timeIntervalSince1970, 1700000000, accuracy: 0.001)
    }

    // MARK: Source enum integrity

    func testEverySourceHasDisplayName() {
        for source in Source.allCases {
            XCTAssertFalse(source.displayName.isEmpty,
                           "Source \(source) is missing a displayName")
        }
    }

    // MARK: Quiet hours scheduling

    func testQuietHoursWrapAround() {
        let prev = (Schedule.enabled, Schedule.startHour, Schedule.endHour)
        defer {
            Schedule.enabled = prev.0
            Schedule.startHour = prev.1
            Schedule.endHour = prev.2
        }
        Schedule.enabled = true
        Schedule.startHour = 22
        Schedule.endHour = 7

        XCTAssertTrue(Schedule.inQuietHours(now: hour(23)))
        XCTAssertTrue(Schedule.inQuietHours(now: hour(2)))
        XCTAssertFalse(Schedule.inQuietHours(now: hour(8)))
        XCTAssertFalse(Schedule.inQuietHours(now: hour(15)))
    }

    func testQuietHoursDisabled() {
        let prev = Schedule.enabled
        defer { Schedule.enabled = prev }
        Schedule.enabled = false
        XCTAssertFalse(Schedule.inQuietHours(now: hour(2)))
    }

    private func hour(_ h: Int) -> Date {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 4; comps.day = 24
        comps.hour = h; comps.minute = 0
        return Calendar.current.date(from: comps)!
    }

    // MARK: Anthropic 429 retry-after parsing

    func testParseRetryAfterFromBody() {
        let body = #"{"error":{"type":"rate_limit_error","message":"please retry in 7s"}}"#
        XCTAssertEqual(AnthropicClient.parseRetryAfter(body: body), 7)
    }

    func testParseRetryAfterAbsent() {
        XCTAssertNil(AnthropicClient.parseRetryAfter(body: "no rate limit info here"))
    }

    // MARK: Slack — prefs parsing

    func testSlackPrefsParseListNormalizesEntries() {
        // Strips leading #, lowercases, trims whitespace, drops empties.
        let parsed = SlackPrefs.parseList(" #General, #INCIDENTS,, oncall ,#bots ")
        XCTAssertEqual(parsed, ["general", "incidents", "oncall", "bots"])
    }

    func testSlackPrefsParseListEmpty() {
        XCTAssertEqual(SlackPrefs.parseList(""), [])
        XCTAssertEqual(SlackPrefs.parseList("   ,  , ,"), [])
    }

    // MARK: Slack — prefs UserDefaults round-trip

    func testSlackPrefsDefaultsAndOverrides() {
        // Use a synthetic teamID so we don't stomp real prefs from the running
        // app, and clean up after ourselves.
        let team = "TEST_TEAM_\(UUID().uuidString)"
        defer { clearSlackPrefs(team: team) }

        let prefs = SlackPrefs(teamID: team)
        // Defaults: DMs/MPIMs/starred on, member channels off.
        XCTAssertTrue(prefs.includeDMs)
        XCTAssertTrue(prefs.includeMPIMs)
        XCTAssertTrue(prefs.includeStarred)
        XCTAssertEqual(prefs.channelMode, .off)
        XCTAssertEqual(prefs.allowlistRaw, "")

        // Overrides persist via UserDefaults and survive re-construction.
        prefs.includeDMs = false
        prefs.channelMode = .mentions
        prefs.allowlistRaw = "#a, #b"
        let again = SlackPrefs(teamID: team)
        XCTAssertFalse(again.includeDMs)
        XCTAssertEqual(again.channelMode, .mentions)
        XCTAssertEqual(again.allowlist, ["a", "b"])
    }

    // MARK: Slack — candidate pre-filter

    func testSlackCandidatesDenylistBeatsEverything() {
        let team = "TEST_TEAM_\(UUID().uuidString)"
        defer { clearSlackPrefs(team: team) }
        let prefs = SlackPrefs(teamID: team)
        prefs.allowlistRaw = "#noisy"   // even an explicit allow doesn't override deny
        prefs.denylistRaw = "#noisy"

        let convo = makeChannel(id: "C1", name: "noisy", isMember: true)
        let result = SlackSource.candidates(from: [convo], prefs: prefs,
                                            cache: SlackStarredCache())
        XCTAssertTrue(result.isEmpty, "denylist should win over allowlist")
    }

    func testSlackCandidatesAllowlistForcesInclusion() {
        let team = "TEST_TEAM_\(UUID().uuidString)"
        defer { clearSlackPrefs(team: team) }
        let prefs = SlackPrefs(teamID: team)
        prefs.allowlistRaw = "#alerts"
        // Channel mode off + not starred in cache → would normally be excluded,
        // but allowlist forces it through.
        let convo = makeChannel(id: "C1", name: "alerts", isMember: true)
        let result = SlackSource.candidates(from: [convo], prefs: prefs,
                                            cache: SlackStarredCache())
        XCTAssertEqual(result.map(\.id), ["C1"])
    }

    func testSlackCandidatesRespectsTypeToggles() {
        let team = "TEST_TEAM_\(UUID().uuidString)"
        defer { clearSlackPrefs(team: team) }
        let prefs = SlackPrefs(teamID: team)
        prefs.includeDMs = false
        prefs.includeMPIMs = true

        let dm = makeIM(id: "D1")
        let groupDM = makeMPIM(id: "G1")
        let result = SlackSource.candidates(from: [dm, groupDM], prefs: prefs,
                                            cache: SlackStarredCache())
        XCTAssertEqual(result.map(\.id), ["G1"])
    }

    func testSlackCandidatesMemberChannelGatedByMode() {
        let team = "TEST_TEAM_\(UUID().uuidString)"
        defer { clearSlackPrefs(team: team) }
        let prefs = SlackPrefs(teamID: team)
        prefs.includeStarred = false  // starred-cache fallback off
        prefs.channelMode = .off

        let convo = makeChannel(id: "C1", name: "general", isMember: true)
        let off = SlackSource.candidates(from: [convo], prefs: prefs,
                                         cache: SlackStarredCache())
        XCTAssertTrue(off.isEmpty)

        prefs.channelMode = .mentions
        let on = SlackSource.candidates(from: [convo], prefs: prefs,
                                        cache: SlackStarredCache())
        XCTAssertEqual(on.map(\.id), ["C1"])
    }

    func testSlackCandidatesIncludesCachedStarredEvenWhenModeOff() {
        let team = "TEST_TEAM_\(UUID().uuidString)"
        defer { clearSlackPrefs(team: team) }
        let prefs = SlackPrefs(teamID: team)
        prefs.channelMode = .off
        prefs.includeStarred = true

        var cache = SlackStarredCache()
        cache.record("C1", isStarred: true)

        let convo = makeChannel(id: "C1", name: "general", isMember: true)
        let result = SlackSource.candidates(from: [convo], prefs: prefs, cache: cache)
        XCTAssertEqual(result.map(\.id), ["C1"])
    }

    func testSlackCandidatesIncludesIMsRegardlessOfIsOpen() {
        // Earlier code required `is_open == true` to drop dormant DMs, but
        // `users.conversations` doesn't actually return that field — so the
        // filter dropped every IM and produced 0 candidates. The fix removes
        // the is_open requirement; bounding now happens via imCandidateCap.
        let team = "TEST_TEAM_\(UUID().uuidString)"
        defer { clearSlackPrefs(team: team) }
        let prefs = SlackPrefs(teamID: team)

        let openIM = makeIM(id: "D_open", isOpen: true)
        let closedIM = makeIM(id: "D_closed", isOpen: false)
        let nilIM = SlackSource.Conversation(
            id: "D_nil", name: nil, is_im: true, is_mpim: false,
            is_channel: false, is_private: false,
            is_member: nil, user: "U", is_open: nil
        )
        let result = SlackSource.candidates(
            from: [openIM, closedIM, nilIM],
            prefs: prefs, cache: SlackStarredCache()
        )
        XCTAssertEqual(Set(result.map(\.id)), ["D_open", "D_closed", "D_nil"])
    }

    func testSlackCandidatesCapsIMs() {
        // Even with includeDMs on, we cap IMs in the candidate set so a
        // 1000-IM workspace can't swamp the conversations.info budget.
        let team = "TEST_TEAM_\(UUID().uuidString)"
        defer { clearSlackPrefs(team: team) }
        let prefs = SlackPrefs(teamID: team)

        let cap = SlackSource.imCandidateCap
        let many = (0..<(cap + 50)).map { makeIM(id: "D\($0)") }
        let mpim = makeMPIM(id: "G1")        // non-IM, must survive
        let channel = makeChannel(id: "C1", name: "watch", isMember: true)
        prefs.allowlistRaw = "#watch"        // allowlisted channel must survive

        let result = SlackSource.candidates(
            from: many + [mpim, channel],
            prefs: prefs, cache: SlackStarredCache()
        )
        let imIDs = result.filter { $0.is_im == true }.map { $0.id }
        XCTAssertEqual(imIDs.count, cap, "IMs must be capped at imCandidateCap")
        // Cap takes the *first* N (Slack's order), so D0..D{cap-1} survive.
        XCTAssertEqual(imIDs.first, "D0")
        XCTAssertEqual(imIDs.last, "D\(cap - 1)")
        // Non-IMs aren't capped.
        XCTAssertTrue(result.contains { $0.id == "G1" })
        XCTAssertTrue(result.contains { $0.id == "C1" })
    }

    func testSlackCandidatesNeverProbesUnknownStarredChannel() {
        // Old behavior bulk-probed every member channel with empty cache to
        // discover stars on first run, which wedged budgets on big workspaces.
        // Verify that includeStarred + empty cache does NOT include unknown
        // channels — they only come in via the explicit discoverStarred path.
        let team = "TEST_TEAM_\(UUID().uuidString)"
        defer { clearSlackPrefs(team: team) }
        let prefs = SlackPrefs(teamID: team)
        prefs.channelMode = .off
        prefs.includeStarred = true

        let unknownChannel = makeChannel(id: "C1", name: "general", isMember: true)
        let result = SlackSource.candidates(
            from: [unknownChannel], prefs: prefs, cache: SlackStarredCache()
        )
        XCTAssertTrue(result.isEmpty,
                      "channels with no cache entry must not be probed during refresh")
    }

    func testSlackCandidatesIncludesChannelsRegardlessOfIsMember() {
        // users.conversations doesn't reliably populate is_member, so checking
        // it dropped every channel from the candidate set on a real workspace.
        // The endpoint only returns conversations the user is part of by
        // contract, so we trust the API and skip the explicit check.
        let team = "TEST_TEAM_\(UUID().uuidString)"
        defer { clearSlackPrefs(team: team) }
        let prefs = SlackPrefs(teamID: team)
        prefs.channelMode = .all

        let nilMember = makeChannel(id: "C1", name: "random", isMember: false)
        let result = SlackSource.candidates(from: [nilMember], prefs: prefs,
                                            cache: SlackStarredCache())
        XCTAssertEqual(result.map(\.id), ["C1"])
    }

    // MARK: Slack — shouldSurface (final filter)

    func testSlackShouldSurfaceDMUnread() {
        let team = "TEST_TEAM_\(UUID().uuidString)"
        defer { clearSlackPrefs(team: team) }
        let prefs = SlackPrefs(teamID: team)

        let withUnread = makeIMInfo(unread: 2)
        let read = makeIMInfo(unread: 0)
        XCTAssertTrue(SlackSource.shouldSurface(withUnread, prefs: prefs))
        XCTAssertFalse(SlackSource.shouldSurface(read, prefs: prefs))
    }

    func testSlackShouldSurfaceDMRespectsToggle() {
        let team = "TEST_TEAM_\(UUID().uuidString)"
        defer { clearSlackPrefs(team: team) }
        let prefs = SlackPrefs(teamID: team)
        prefs.includeDMs = false

        let withUnread = makeIMInfo(unread: 2)
        XCTAssertFalse(SlackSource.shouldSurface(withUnread, prefs: prefs))
    }

    func testSlackShouldSurfaceMemberChannelMentionsMode() {
        let team = "TEST_TEAM_\(UUID().uuidString)"
        defer { clearSlackPrefs(team: team) }
        let prefs = SlackPrefs(teamID: team)
        prefs.channelMode = .mentions
        prefs.includeStarred = false

        // Five unread, none of which are mentions/threads.
        let chatter = makeChannelInfo(name: "general", unread: 5, mentions: 0)
        XCTAssertFalse(SlackSource.shouldSurface(chatter, prefs: prefs))

        // One mention badge → surface.
        let mentioned = makeChannelInfo(name: "general", unread: 5, mentions: 1)
        XCTAssertTrue(SlackSource.shouldSurface(mentioned, prefs: prefs))
    }

    func testSlackShouldSurfaceMemberChannelAllMode() {
        let team = "TEST_TEAM_\(UUID().uuidString)"
        defer { clearSlackPrefs(team: team) }
        let prefs = SlackPrefs(teamID: team)
        prefs.channelMode = .all
        prefs.includeStarred = false

        // Any unread message qualifies in `all` mode, even without mentions.
        let info = makeChannelInfo(name: "general", unread: 1, mentions: 0)
        XCTAssertTrue(SlackSource.shouldSurface(info, prefs: prefs))
    }

    func testSlackShouldSurfaceStarredOverridesMode() {
        let team = "TEST_TEAM_\(UUID().uuidString)"
        defer { clearSlackPrefs(team: team) }
        let prefs = SlackPrefs(teamID: team)
        prefs.channelMode = .off  // explicitly off
        prefs.includeStarred = true

        // Starred channel with one unread → surface despite mode == off.
        let starred = makeChannelInfo(name: "general", unread: 1, mentions: 0,
                                      isStarred: true)
        XCTAssertTrue(SlackSource.shouldSurface(starred, prefs: prefs))

        // Same channel without unreads → don't surface (we never push read msgs).
        let starredRead = makeChannelInfo(name: "general", unread: 0, mentions: 0,
                                          isStarred: true)
        XCTAssertFalse(SlackSource.shouldSurface(starredRead, prefs: prefs))
    }

    func testSlackShouldSurfaceDenylistAlwaysWins() {
        let team = "TEST_TEAM_\(UUID().uuidString)"
        defer { clearSlackPrefs(team: team) }
        let prefs = SlackPrefs(teamID: team)
        prefs.channelMode = .all
        prefs.includeStarred = true
        prefs.denylistRaw = "#general"

        // Even a starred + unread + allow-mode channel gets dropped if denied.
        let info = makeChannelInfo(name: "general", unread: 5, mentions: 5,
                                   isStarred: true)
        XCTAssertFalse(SlackSource.shouldSurface(info, prefs: prefs))
    }

    // MARK: - Slack test helpers

    private func makeChannel(id: String, name: String, isMember: Bool) -> SlackSource.Conversation {
        SlackSource.Conversation(
            id: id, name: name,
            is_im: false, is_mpim: false,
            is_channel: true, is_private: false,
            is_member: isMember, user: nil, is_open: nil
        )
    }

    private func makeIM(id: String, isOpen: Bool = true) -> SlackSource.Conversation {
        SlackSource.Conversation(
            id: id, name: nil,
            is_im: true, is_mpim: false,
            is_channel: false, is_private: false,
            is_member: nil, user: "U_partner", is_open: isOpen
        )
    }

    private func makeMPIM(id: String, isOpen: Bool = true) -> SlackSource.Conversation {
        SlackSource.Conversation(
            id: id, name: nil,
            is_im: false, is_mpim: true,
            is_channel: false, is_private: false,
            is_member: nil, user: nil, is_open: isOpen
        )
    }

    private func makeIMInfo(unread: Int) -> SlackSource.ConversationInfo {
        SlackSource.ConversationInfo(
            id: "D1", name: nil, isIM: true, isMPIM: false,
            dmUser: "U_partner", isStarred: false,
            unreadCount: unread, unreadCountDisplay: unread, lastReadTS: nil
        )
    }

    private func makeChannelInfo(name: String, unread: Int, mentions: Int,
                                 isStarred: Bool = false) -> SlackSource.ConversationInfo {
        SlackSource.ConversationInfo(
            id: "C1", name: name, isIM: false, isMPIM: false,
            dmUser: nil, isStarred: isStarred,
            unreadCount: unread, unreadCountDisplay: mentions, lastReadTS: nil
        )
    }

    /// Wipe the UserDefaults keys our SlackPrefs writes for a synthetic teamID.
    private func clearSlackPrefs(team: String) {
        let d = UserDefaults.standard
        for k in ["includeDMs", "includeMPIMs", "includeStarred",
                  "channelMode", "allowlist", "denylist", "starredCache"] {
            d.removeObject(forKey: "lede.slack.\(team).\(k)")
        }
    }
}
