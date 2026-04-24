import Foundation
import CryptoKit

enum Source: String, Codable, CaseIterable, Identifiable {
    case github
    case gmail
    case slack   // stubbed
    case outlook // stubbed

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .github: return "GitHub"
        case .gmail: return "Gmail"
        case .slack: return "Slack"
        case .outlook: return "Outlook"
        }
    }
}

/// Raw item pulled from a source before any LLM processing.
struct RawItem: Codable, Hashable {
    let id: String              // stable source-local id
    let source: Source
    let title: String
    let sender: String?
    let snippet: String         // plain text, truncated upstream
    let url: URL?
    let receivedAt: Date
    let isUnread: Bool

    /// Stable hash over semantic content. Used to cache summaries so unchanged items are never re-summarized.
    var contentHash: String {
        var hasher = SHA256()
        hasher.update(data: Data(source.rawValue.utf8))
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

/// The final digest rendered in the panel.
struct Digest: Codable {
    struct Item: Codable, Identifiable, Hashable {
        var id: String { contentHash }
        let contentHash: String
        let source: Source
        let title: String
        let sender: String?
        let url: URL?
        let receivedAt: Date
        let score: Int
        let summary: String
        let reason: String
    }
    let generatedAt: Date
    let items: [Item]           // sorted desc by score
    let synthesis: String?      // optional 2-3 sentence cross-source meta-summary
}
