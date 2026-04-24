import Foundation

/// Two-stage LLM pipeline. Designed around three token-saving principles:
///
///   1. **Cache by content hash.** We only send items the model has never seen.
///      An item that comes back unchanged (same hash) costs zero tokens.
///
///   2. **Cheap triage, expensive synthesis.** Haiku scores each new item
///      (0..10 + one-line summary). Only the top-N across all sources get
///      rolled into a Sonnet synthesis. Sonnet cost is O(top-N), not O(inbox).
///
///   3. **Prompt caching.** The system prompt for triage is stable and marked
///      `cache_control: ephemeral`, so repeated triage calls in a 5-minute
///      window get a ~90% discount on input tokens.
struct TriagePipeline {
    let client: AnthropicClient
    let storage: Storage

    /// Per-item Haiku triage output contract. Tight JSON to keep output tokens low.
    private struct TriageJSON: Codable {
        let score: Int
        let summary: String
        let reason: String
    }

    private static let triageSystem = """
        You triage incoming notifications (email, GitHub, chat) for a busy engineer.
        For each item, decide how important it is RIGHT NOW and summarize briefly.

        Score rubric (0..10):
          10 - production outage, urgent ask from a direct report/manager, security
           8 - requires a reply today, blocks someone's work, review requested by teammate
           6 - informational but relevant to current work, CI failed on their PR
           4 - FYI / low-priority mention
           2 - newsletters, routine notifications, bot chatter
           0 - spam, automated

        Return STRICT JSON only. No preface. No code fences. Schema:
          {"score": int 0..10, "summary": "<=140 chars factual", "reason": "<=60 chars"}
        """

    private static let synthesisSystem = """
        You are a concise briefing assistant. Given a ranked list of notifications
        from multiple sources, write a 2-3 sentence synthesis that names the two
        or three things the user should look at first. Be specific (mention sender/repo).
        No preamble, no closing. Plain text only.
        """

    /// Run triage on new items, return a digest.
    func run(items: [RawItem]) async throws -> Digest {
        // Dedupe by content hash.
        var unique: [String: RawItem] = [:]
        for item in items { unique[item.contentHash] = item }
        let deduped = Array(unique.values)

        // Split: cached vs. needs-triage.
        var triaged: [String: ItemTriage] = [:]
        var toTriage: [RawItem] = []
        for item in deduped {
            if let cached = await storage.getTriage(for: item.contentHash) {
                triaged[item.contentHash] = cached
            } else {
                toTriage.append(item)
            }
        }

        // Triage new items sequentially. Prompt cache keeps subsequent calls cheap.
        // (Parallelism would fight the cache — stay sequential.)
        for item in toTriage {
            do {
                let t = try await triageOne(item)
                triaged[item.contentHash] = t
                await storage.putTriage(t)
            } catch {
                // Fall back to a neutral triage so the item still shows up.
                let t = ItemTriage(
                    contentHash: item.contentHash,
                    score: 4,
                    summary: String(item.title.prefix(140)),
                    reason: "triage failed",
                    createdAt: Date()
                )
                triaged[item.contentHash] = t
            }
        }

        // Assemble digest items, sort desc by score then recency.
        let rawByHash = Dictionary(uniqueKeysWithValues: deduped.map { ($0.contentHash, $0) })
        var digestItems: [Digest.Item] = triaged.values.compactMap { t in
            guard let raw = rawByHash[t.contentHash] else { return nil }
            return Digest.Item(
                contentHash: t.contentHash,
                source: raw.source,
                title: raw.title,
                sender: raw.sender,
                url: raw.url,
                receivedAt: raw.receivedAt,
                score: t.score,
                summary: t.summary,
                reason: t.reason
            )
        }
        digestItems.sort { (a, b) in
            if a.score != b.score { return a.score > b.score }
            return a.receivedAt > b.receivedAt
        }

        // Synthesis over top 8 — only if the top item is actually interesting.
        var synthesis: String? = nil
        let topN = Array(digestItems.prefix(8))
        if let first = topN.first, first.score >= 6, topN.count >= 2 {
            synthesis = try? await synthesize(topN)
        }

        let digest = Digest(generatedAt: Date(), items: digestItems, synthesis: synthesis)
        await storage.saveDigest(digest)
        return digest
    }

    // MARK: -

    private func triageOne(_ item: RawItem) async throws -> ItemTriage {
        let user = """
            SOURCE: \(item.source.displayName)
            FROM: \(item.sender ?? "(unknown)")
            TITLE: \(item.title)
            SNIPPET: \(item.snippet)
            """

        let result = try await client.complete(
            model: AnthropicClient.modelTriage,
            systemCached: Self.triageSystem,
            user: user,
            maxTokens: 200,
            temperature: 0
        )
        let parsed = try parseTriageJSON(result.text)
        return ItemTriage(
            contentHash: item.contentHash,
            score: min(10, max(0, parsed.score)),
            summary: String(parsed.summary.prefix(180)),
            reason: String(parsed.reason.prefix(80)),
            createdAt: Date()
        )
    }

    private func parseTriageJSON(_ text: String) throws -> TriageJSON {
        // Haiku usually returns clean JSON, but strip any accidental fences.
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            s = s.replacingOccurrences(of: "```json", with: "")
            s = s.replacingOccurrences(of: "```", with: "")
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let data = s.data(using: .utf8) else {
            throw AnthropicError.decoding("not utf8")
        }
        return try JSONDecoder().decode(TriageJSON.self, from: data)
    }

    private func synthesize(_ items: [Digest.Item]) async throws -> String {
        let lines = items.enumerated().map { idx, i in
            "\(idx + 1). [\(i.source.displayName) · score \(i.score)] \(i.summary) — \(i.reason)"
        }.joined(separator: "\n")

        let result = try await client.complete(
            model: AnthropicClient.modelSynthesis,
            systemCached: Self.synthesisSystem,
            user: "Top items:\n\(lines)",
            maxTokens: 200,
            temperature: 0.2
        )
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
