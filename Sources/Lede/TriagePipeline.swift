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

    /// Bump this when the prompt changes — it's mixed into the triage cache key
    /// so prompt edits invalidate previously-cached scores.
    static let promptVersion = "v2"

    private static let triageSystem = """
        You triage incoming notifications (email, GitHub, chat) for a busy engineer.
        The user is drowning in low-value noise. Be ruthless: most items should
        score 0–3. Only raise the score when there's a clear reason to look NOW.

        Score rubric (0..10):
          10 - production outage, urgent ask from manager/CEO, security alert
           8 - requires a reply today, blocks a teammate, review requested on their PR
           6 - direct @mention, CI failed on their PR, issue assigned to them
           4 - FYI they'd want to glance at once
           2 - routine automated notification, subscription digest, build-passed emails,
               Dependabot, "a user you follow did X"
           0 - spam, abuse, harassment, promotional newsletter, bot-only chatter,
               automated notifications the user never acts on

        Concrete examples:
          "Your deploy succeeded"                              → 1
          "GitHub Actions workflow succeeded on main"          → 1
          "Dependabot: update lodash"                          → 2
          "Newsletter: this week in ML"                        → 0
          "PR review requested from you"                       → 8
          "Your PR has merge conflicts"                        → 6
          "Someone @mentioned you in #eng-alerts"              → 7
          "Offensive / abusive message"                        → 0
          "A user you follow pushed to main"                   → 1
          "Security advisory affects your repo"                → 9

        If unsure, score LOWER, not higher. The user can re-read later; they cannot
        un-see a notification you pushed in their face.

        Return STRICT JSON only. No preface. No code fences. Schema:
          {"score": int 0..10, "summary": "<=140 chars factual", "reason": "<=60 chars"}
        """

    private static let synthesisSystem = """
        You are a concise briefing assistant. Given a ranked list of notifications
        from multiple sources, write a 2-3 sentence synthesis that names the two
        or three things the user should look at first. Be specific (mention sender/repo).
        No preamble, no closing. Plain text only.
        """

    /// Cache key = prompt-version + content-hash, so changing the prompt
    /// invalidates cached triages automatically.
    private func cacheKey(for item: RawItem) -> String {
        "\(Self.promptVersion):\(item.contentHash)"
    }

    /// Run triage on new items, return a digest.
    func run(items: [RawItem]) async throws -> Digest {
        // Dedupe by content hash.
        var unique: [String: RawItem] = [:]
        for item in items { unique[item.contentHash] = item }
        let deduped = Array(unique.values)
        Log.info("triage: \(items.count) in → \(deduped.count) after dedupe")

        // Split: cached vs. needs-triage.
        var triaged: [String: ItemTriage] = [:]
        var toTriage: [RawItem] = []
        for item in deduped {
            if let cached = await storage.getTriage(for: cacheKey(for: item)) {
                triaged[item.contentHash] = cached
            } else {
                toTriage.append(item)
            }
        }
        Log.info("triage: \(triaged.count) cache hit, \(toTriage.count) to score")

        // Triage new items sequentially. Prompt cache keeps subsequent calls cheap.
        // (Parallelism would fight the cache — stay sequential.)
        for item in toTriage {
            do {
                let t = try await triageOne(item)
                triaged[item.contentHash] = t
                // Persist under the versioned cache key. Note: we deliberately
                // store the ItemTriage with its contentHash field set to the
                // versioned key (that's Storage's primary key), but then the
                // in-memory `triaged` dict keys it by the plain contentHash so
                // assembly below can zip it with RawItems.
                await storage.putTriage(ItemTriage(
                    contentHash: cacheKey(for: item),
                    score: t.score,
                    summary: t.summary,
                    reason: t.reason,
                    createdAt: t.createdAt
                ))
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

        // Assemble digest items. Key on the dict-key (plain content hash) since
        // cached ItemTriages carry a *versioned* hash in their own field (the
        // Storage primary key), which doesn't match the RawItem hashes.
        let rawByHash = Dictionary(uniqueKeysWithValues: deduped.map { ($0.contentHash, $0) })
        var digestItems: [Digest.Item] = triaged.compactMap { hash, t in
            guard let raw = rawByHash[hash] else { return nil }
            return Digest.Item(
                contentHash: hash,
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

        // Sticky merge: keep items from the previous digest that aren't in this
        // fetch, as long as they're recent (< 24h). Prevents items vanishing
        // when a source silently stops returning them — e.g. Gmail flipping
        // an email to read-state because another client opened it.
        let currentHashes = Set(digestItems.map { $0.contentHash })
        let stickyTTL: TimeInterval = 24 * 3600
        let now = Date()
        if let previous = await storage.loadLastDigest() {
            for old in previous.items where !currentHashes.contains(old.contentHash) {
                if now.timeIntervalSince(old.receivedAt) < stickyTTL {
                    digestItems.append(old)
                }
            }
        }

        // Drop items the user has explicitly dismissed (persists across refreshes).
        let dismissed = await storage.allDismissed()
        let beforeDismiss = digestItems.count
        digestItems.removeAll { dismissed.contains($0.contentHash) }
        if beforeDismiss != digestItems.count {
            Log.info("triage: dropped \(beforeDismiss - digestItems.count) dismissed item(s)")
        }
        Log.info("triage: final digest = \(digestItems.count) item(s)")

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
        await recordUsage(model: AnthropicClient.modelTriage, usage: result.usage)
        let parsed = try parseTriageJSON(result.text)
        return ItemTriage(
            contentHash: item.contentHash,
            score: min(10, max(0, parsed.score)),
            summary: String(parsed.summary.prefix(180)),
            reason: String(parsed.reason.prefix(80)),
            createdAt: Date()
        )
    }

    private func recordUsage(model: String, usage: AnthropicClient.Usage?) async {
        guard let u = usage else { return }
        await storage.addUsage(
            model: model,
            input: u.input_tokens ?? 0,
            output: u.output_tokens ?? 0,
            cacheReads: u.cache_read_input_tokens ?? 0,
            cacheWrites: u.cache_creation_input_tokens ?? 0
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
        await recordUsage(model: AnthropicClient.modelSynthesis, usage: result.usage)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
