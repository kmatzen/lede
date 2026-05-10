import Foundation

protocol NotificationSource {
    var account: Account { get }
    var source: Source { get }
    var isConfigured: Bool { get }
    /// Returns recent items (caller will cap + dedupe). The result also
    /// reports how many additional unread items the source had but we
    /// chose not to pull because we hit the per-source soft cap — used
    /// to surface a "N older items not shown" hint in the panel.
    func fetch() async throws -> FetchResult
}

/// Output of one source's fetch. Splits the items returned from a
/// lower-bound count of items deliberately not pulled (pagination cap).
struct FetchResult {
    let items: [RawItem]
    /// Lower bound on unread items not pulled because the per-source
    /// soft cap was hit. 0 when the source was fully drained. Sources
    /// whose APIs expose a result total (e.g. Slack `total`) report
    /// exact counts; sources that only expose a next-page cursor
    /// (Gmail / Outlook / GitHub) report `1` as a "≥1" hint.
    let omitted: Int

    init(items: [RawItem], omitted: Int = 0) {
        self.items = items
        self.omitted = max(0, omitted)
    }
}

/// Per-source soft cap on items pulled in a single fetch. Beyond this we
/// stop walking the cursor and surface "N older items not shown" so
/// vacation-return moments don't silently lose older unreads — the cap
/// keeps each fetch bounded in latency, memory, and downstream Claude
/// triage cost.
enum SourcePagination {
    static let softCap = 200
}

struct SourceError: Error, LocalizedError {
    let source: Source
    let message: String
    var errorDescription: String? { "\(source.displayName): \(message)" }
}
