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

    // MARK: Slack — entity rewriting

    func testSlackRewriteEntitiesUserToken() {
        // <@USERID> rewrites via the users dict; the signed-in user becomes @me.
        let users = ["U1": "Alice", "U2": "Bob"]
        let out = SlackSource.rewriteEntities("hi <@U1> and <@U2>", users: users, selfID: "U2")
        XCTAssertEqual(out, "hi @Alice and @me")
    }

    func testSlackRewriteEntitiesChannelToken() {
        let out = SlackSource.rewriteEntities("see <#C1|general>", users: [:], selfID: nil)
        XCTAssertEqual(out, "see #general")
    }

    func testSlackRewriteEntitiesBangToken() {
        let here = SlackSource.rewriteEntities("<!here>", users: [:], selfID: nil)
        XCTAssertEqual(here, "@here")
        let subteam = SlackSource.rewriteEntities("<!subteam^S0|@oncall>", users: [:], selfID: nil)
        XCTAssertEqual(subteam, "@@oncall")
    }

    /// Wipe the UserDefaults keys our SlackPrefs writes for a synthetic teamID.
    private func clearSlackPrefs(team: String) {
        let d = UserDefaults.standard
        for k in ["includeDMs", "includeMPIMs", "includeStarred",
                  "channelMode", "allowlist", "denylist",
                  "starredCache", "autoDiscoveryInitiated"] {
            d.removeObject(forKey: "lede.slack.\(team).\(k)")
        }
    }

    // MARK: GitHub Link header parsing

    func testGitHubParseNextLinkPicksRelNext() {
        let header = "<https://api.github.com/notifications?page=2>; rel=\"next\", <https://api.github.com/notifications?page=5>; rel=\"last\""
        let next = GitHubSource.parseNextLink(header)
        XCTAssertEqual(next?.absoluteString, "https://api.github.com/notifications?page=2")
    }

    func testGitHubParseNextLinkAbsentOnLastPage() {
        let header = "<https://api.github.com/notifications?page=1>; rel=\"prev\", <https://api.github.com/notifications?page=1>; rel=\"first\""
        XCTAssertNil(GitHubSource.parseNextLink(header))
    }

    func testGitHubParseNextLinkEmptyHeader() {
        XCTAssertNil(GitHubSource.parseNextLink(""))
    }

    // MARK: SourceState codable

    func testSourceStateDecodesLegacyJSONWithoutOmittedCount() throws {
        // State files written before pagination landed don't have the
        // `omittedCount` key. Decoding must default it to 0 so we don't
        // wipe every source's health snapshot on first launch after upgrade.
        let json = #"{"lastFetchedAt":"2026-05-10T00:00:00Z","lastItemCount":17}"#
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let s = try dec.decode(SourceState.self, from: Data(json.utf8))
        XCTAssertEqual(s.lastItemCount, 17)
        XCTAssertEqual(s.omittedCount, 0)
        XCTAssertNil(s.lastError)
    }

    func testSourceStateDecodesNewJSONWithOmittedCount() throws {
        let json = #"{"lastItemCount":200,"omittedCount":42}"#
        let s = try JSONDecoder().decode(SourceState.self, from: Data(json.utf8))
        XCTAssertEqual(s.lastItemCount, 200)
        XCTAssertEqual(s.omittedCount, 42)
    }

    func testSourceStateDecodesLegacyJSONWithoutRegressionFields() throws {
        // State files written before the regression-detection landed
        // had neither `recentItemCounts` nor `regressionHint`. Decoding
        // must default them or every source's history gets wiped.
        let json = #"{"lastItemCount":12,"omittedCount":0}"#
        let s = try JSONDecoder().decode(SourceState.self, from: Data(json.utf8))
        XCTAssertEqual(s.recentItemCounts, [])
        XCTAssertNil(s.regressionHint)
    }

    // MARK: Source regression hint

    func testRegressionHintFiresOnZeroAfterActivity() {
        let hint = CoreEngine.regressionHint(
            currentCount: 0, priorWindow: [12, 14, 0, 9],
            source: .gmail, accountLabel: "kev@example.com"
        )
        XCTAssertEqual(hint, "Gmail (kev@example.com) returned 0 — check connection?")
    }

    func testRegressionHintQuietWhenCurrentNonZero() {
        // Even with prior activity, a non-zero current means we're
        // still hearing from the source. No hint needed.
        let hint = CoreEngine.regressionHint(
            currentCount: 3, priorWindow: [10, 11, 12, 13],
            source: .gmail, accountLabel: "kev@example.com"
        )
        XCTAssertNil(hint)
    }

    func testRegressionHintQuietWhenPriorWindowIsLow() {
        // 0 of 0 of 0 → user is genuinely caught up; a brand-new account
        // ramping up; etc. Don't cry wolf.
        XCTAssertNil(CoreEngine.regressionHint(
            currentCount: 0, priorWindow: [0, 0, 1],
            source: .gmail, accountLabel: "kev@example.com"
        ))
        XCTAssertNil(CoreEngine.regressionHint(
            currentCount: 0, priorWindow: [],
            source: .gmail, accountLabel: "kev@example.com"
        ))
    }

    func testRegressionHintBoundaryAtFive() {
        // priorMax must exceed 5 — a single 6 trips it; a 5 doesn't.
        XCTAssertNotNil(CoreEngine.regressionHint(
            currentCount: 0, priorWindow: [0, 0, 6],
            source: .slack, accountLabel: "team"
        ))
        XCTAssertNil(CoreEngine.regressionHint(
            currentCount: 0, priorWindow: [5, 5, 5],
            source: .slack, accountLabel: "team"
        ))
    }
}
