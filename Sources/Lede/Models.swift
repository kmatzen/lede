import Foundation
import CryptoKit

enum Source: String, Codable, CaseIterable, Identifiable {
    case github
    case gmail
    case slack
    case outlook
    case calendar

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .github: return "GitHub"
        case .gmail: return "Gmail"
        case .slack: return "Slack"
        case .outlook: return "Outlook"
        case .calendar: return "Calendar"
        }
    }

    /// Per-source on/off toggle. Defaults to true so newly added sources
    /// participate without the user having to flip a switch.
    var isEnabledByUser: Bool {
        get {
            let key = "lede.source.enabled.\(rawValue)"
            if UserDefaults.standard.object(forKey: key) == nil { return true }
            return UserDefaults.standard.bool(forKey: key)
        }
        nonmutating set {
            UserDefaults.standard.set(newValue, forKey: "lede.source.enabled.\(rawValue)")
        }
    }
}

/// The OAuth identity that backs one or more Sources. A Google Account drives
/// both Gmail and Calendar from a single grant; a Microsoft Account drives
/// both Outlook and Calendar. GitHub and Slack each drive a single Source.
enum Provider: String, Codable, CaseIterable, Identifiable {
    case github
    case google
    case slack
    case microsoft

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .github: return "GitHub"
        case .google: return "Google"
        case .slack: return "Slack"
        case .microsoft: return "Microsoft"
        }
    }

    /// Sources this provider populates.
    var sources: [Source] {
        switch self {
        case .github: return [.github]
        case .google: return [.gmail, .calendar]
        case .slack: return [.slack]
        case .microsoft: return [.outlook, .calendar]
        }
    }
}

/// One OAuth grant, identified by its provider-stable id (Gmail address,
/// GitHub login, Slack team_id, Microsoft user objectId). The user can have
/// multiple Accounts of the same Provider — e.g. personal + work Google.
struct Account: Codable, Hashable, Identifiable {
    let provider: Provider
    let id: String              // provider-stable id, used as keychain suffix
    var label: String           // human-readable: email address, workspace name, etc.
    let connectedAt: Date

    /// Composite key used to namespace per-account state (Keychain entries,
    /// SourceState dictionaries). Stable across renames of `label`.
    var key: String { "\(provider.rawValue):\(id)" }
}

/// On-disk registry of every connected Account.
struct AccountsRegistry: Codable {
    var accounts: [Account] = []
}

/// Raw item pulled from a source before any LLM processing.
struct RawItem: Codable, Hashable {
    let id: String              // stable source-local id
    let source: Source
    /// Account this item came from. Optional only because pre-migration code
    /// paths may construct items without an account; new code always sets it.
    let accountID: String?
    let accountLabel: String?
    let title: String
    let sender: String?
    let snippet: String         // plain text, truncated upstream
    let url: URL?
    let receivedAt: Date
    let isUnread: Bool

    /// Stable hash over semantic content. Mixes in accountID so an identical
    /// message that lands in two different accounts produces two distinct
    /// items in the digest (rather than one collapsing on top of the other).
    var contentHash: String {
        var hasher = SHA256()
        hasher.update(data: Data(source.rawValue.utf8))
        hasher.update(data: Data((accountID ?? "").utf8))
        hasher.update(data: Data(id.utf8))
        hasher.update(data: Data(title.utf8))
        hasher.update(data: Data((sender ?? "").utf8))
        hasher.update(data: Data(snippet.utf8))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Per-item triage from the fast model (Haiku).
struct ItemTriage: Codable, Hashable {
    let contentHash: String
    let score: Int              // 0..10 importance
    let summary: String         // <= ~140 chars
    let reason: String          // why it matters, one phrase
    let createdAt: Date
}

/// Per-source health snapshot — surfaced in Settings so the user can see at
/// a glance whether each connection is actually working. Now keyed per
/// (account, source) so a failure on Work Gmail doesn't mask Personal Gmail.
struct SourceState: Codable, Equatable {
    var lastFetchedAt: Date?
    var lastItemCount: Int = 0
    var lastError: String?
    /// Lower bound on unread items that existed on the server but we
    /// didn't pull because the per-source soft cap kicked in. 0 when
    /// fully drained. Surfaced in the panel footer as "N older items
    /// not shown" so vacation-returners can tell their feed is capped.
    var omittedCount: Int = 0

    init(lastFetchedAt: Date? = nil, lastItemCount: Int = 0,
         lastError: String? = nil, omittedCount: Int = 0) {
        self.lastFetchedAt = lastFetchedAt
        self.lastItemCount = lastItemCount
        self.lastError = lastError
        self.omittedCount = omittedCount
    }

    private enum CodingKeys: String, CodingKey {
        case lastFetchedAt, lastItemCount, lastError, omittedCount
    }

    /// Hand-written decoder so state files written before pagination
    /// landed (no `omittedCount` field) keep decoding cleanly — the
    /// outer dictionary loader uses `try?` and would otherwise drop
    /// every source's state on the first launch after the upgrade.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.lastFetchedAt = try c.decodeIfPresent(Date.self, forKey: .lastFetchedAt)
        self.lastItemCount = try c.decodeIfPresent(Int.self, forKey: .lastItemCount) ?? 0
        self.lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
        self.omittedCount = try c.decodeIfPresent(Int.self, forKey: .omittedCount) ?? 0
    }
}

/// Token totals keyed by model — different prices, different rates.
struct ModelUsage: Codable, Equatable {
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheReads: Int = 0
    var cacheWrites: Int = 0
}

/// Running tally of Anthropic API token usage, broken out per model so we
/// can apply the right pricing. Resets at the start of each calendar month.
struct UsageTotals: Codable, Equatable {
    /// Legacy flat counters — kept so existing usage.json files decode.
    /// Treated as Haiku-tier when computing totals.
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheReads: Int = 0
    var cacheWrites: Int = 0
    /// Per-model breakdown (keys are model IDs like "claude-haiku-4-5").
    var byModel: [String: ModelUsage] = [:]
    /// Calendar month boundary the totals reset on. Format "yyyy-MM".
    var monthKey: String = ""
}

/// The final digest rendered in the panel.
struct Digest: Codable {
    struct Item: Codable, Identifiable, Hashable {
        var id: String { contentHash }
        let contentHash: String
        let source: Source
        /// Optional only for backward-compat with last_digest.json files
        /// written before multi-account support landed.
        let accountID: String?
        let accountLabel: String?
        let title: String
        let sender: String?
        let url: URL?
        let receivedAt: Date
        /// 0..10 from Haiku triage. Sentinel `-1` means "not yet ranked"
        /// (manual-Claude mode), in which case the row appears under
        /// `unprocessed` rather than `items`.
        let score: Int
        let summary: String
        let reason: String
    }
    let generatedAt: Date
    let items: [Item]           // sorted desc by score
    let synthesis: String?      // optional 2-3 sentence cross-source meta-summary
    /// Items fetched from sources but not yet ranked by Claude. Populated
    /// only when the user has manual-Claude mode on; always empty otherwise.
    let unprocessed: [Item]

    init(generatedAt: Date, items: [Item], synthesis: String?, unprocessed: [Item] = []) {
        self.generatedAt = generatedAt
        self.items = items
        self.synthesis = synthesis
        self.unprocessed = unprocessed
    }

    private enum CodingKeys: String, CodingKey {
        case generatedAt, items, synthesis, unprocessed
    }

    /// Hand-written decoder so digests written before manual-mode landed
    /// (no `unprocessed` field) still decode cleanly.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.generatedAt = try c.decode(Date.self, forKey: .generatedAt)
        self.items = try c.decode([Item].self, forKey: .items)
        self.synthesis = try c.decodeIfPresent(String.self, forKey: .synthesis)
        self.unprocessed = try c.decodeIfPresent([Item].self, forKey: .unprocessed) ?? []
    }
}
