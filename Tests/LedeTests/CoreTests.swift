import XCTest
@testable import Lede

final class CoreTests: XCTestCase {

    // MARK: contentHash

    func testContentHashIsDeterministic() {
        let a = RawItem(
            id: "1", source: .github, title: "PR review",
            sender: "alice", snippet: "ready for review",
            url: nil, receivedAt: Date(timeIntervalSince1970: 0), isUnread: true
        )
        let b = a
        XCTAssertEqual(a.contentHash, b.contentHash)
    }

    func testContentHashChangesWithSemanticFields() {
        let base = RawItem(
            id: "1", source: .github, title: "PR review",
            sender: "alice", snippet: "ready",
            url: nil, receivedAt: Date(), isUnread: true
        )
        var titleChanged = base; titleChanged = RawItem(
            id: base.id, source: base.source, title: "PR REVIEW (urgent)",
            sender: base.sender, snippet: base.snippet,
            url: base.url, receivedAt: base.receivedAt, isUnread: base.isUnread
        )
        XCTAssertNotEqual(base.contentHash, titleChanged.contentHash)
    }

    func testContentHashIgnoresReceivedAtAndUnread() {
        // Only id/source/title/sender/snippet feed the hash. Re-fetching the
        // same message at a different moment, or the user reading it elsewhere,
        // shouldn't invalidate its triage cache entry.
        let a = RawItem(id: "1", source: .gmail, title: "t", sender: "s",
                        snippet: "x", url: nil, receivedAt: Date(timeIntervalSince1970: 0), isUnread: true)
        let b = RawItem(id: "1", source: .gmail, title: "t", sender: "s",
                        snippet: "x", url: nil, receivedAt: Date(timeIntervalSince1970: 9999), isUnread: false)
        XCTAssertEqual(a.contentHash, b.contentHash)
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
}
