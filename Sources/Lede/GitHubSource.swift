import Foundation

/// Reads notifications using whichever credential is stored under the account
/// (OAuth bearer from device flow, or a personal access token saved manually).
struct GitHubSource: NotificationSource {
    let account: Account
    let source: Source = .github

    var isConfigured: Bool {
        GitHubOAuth.token(forAccount: account.id) != nil
    }

    func fetch() async throws -> FetchResult {
        guard let token = GitHubOAuth.token(forAccount: account.id) else {
            return FetchResult(items: [])
        }

        // Walk the `Link: rel="next"` cursor — GitHub's standard pagination
        // header — until the cap is hit or there's no next page. `per_page=50`
        // matches the previous behavior; the cap bounds total pages walked.
        let cap = SourcePagination.softCap
        var notifs: [GHNotification] = []
        var nextURL: URL? = URL(string: "https://api.github.com/notifications?per_page=50&all=false")
        var omitted = 0

        while let url = nextURL {
            var req = URLRequest(url: url)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            req.setValue("Lede/0.1", forHTTPHeaderField: "User-Agent")

            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? ""
                throw SourceError(source: source, message: "HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0) \(body.prefix(200))")
            }
            let page = try JSONDecoder.iso.decode([GHNotification].self, from: data)
            notifs.append(contentsOf: page)

            let linkHeader = http.value(forHTTPHeaderField: "Link") ?? ""
            let parsedNext = Self.parseNextLink(linkHeader)

            if notifs.count >= cap {
                if notifs.count > cap {
                    omitted = max(omitted, notifs.count - cap)
                    notifs = Array(notifs.prefix(cap))
                }
                if parsedNext != nil {
                    omitted = max(omitted, 1)
                }
                nextURL = nil
            } else {
                nextURL = parsedNext
            }
        }

        let acct = account
        let items: [RawItem] = notifs.compactMap { n in
            let url = Self.htmlURL(for: n)
            return RawItem(
                id: n.id,
                source: .github,
                accountID: acct.id,
                accountLabel: acct.label,
                title: "\(n.repository.full_name): \(n.subject.title)",
                sender: n.repository.full_name,
                snippet: "\(n.reason) · \(n.subject.type)",
                url: url,
                receivedAt: n.updated_at,
                isUnread: n.unread
            )
        }
        Log.info("github[\(acct.label)]: returned \(items.count) notification(s)\(omitted > 0 ? " (cap hit, ≥\(omitted) more)" : "")")
        return FetchResult(items: items, omitted: omitted)
    }

    /// Extract the `rel="next"` URL from a GitHub `Link` header. Format is
    /// `<url>; rel="next", <url>; rel="last"` per RFC 5988. Returns nil
    /// when no `next` is advertised (final page).
    static func parseNextLink(_ header: String) -> URL? {
        for part in header.split(separator: ",") {
            let segs = part.split(separator: ";", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard segs.count == 2 else { continue }
            let rel = segs[1].replacingOccurrences(of: " ", with: "")
            guard rel == "rel=\"next\"" || rel == "rel=next" else { continue }
            var url = segs[0]
            if url.hasPrefix("<") { url.removeFirst() }
            if url.hasSuffix(">") { url.removeLast() }
            return URL(string: url)
        }
        return nil
    }

    /// Convert a GitHub notification to a user-facing URL. The
    /// notifications API hands us an `api.github.com/repos/...` URL in
    /// `subject.url`; for some types it maps cleanly to an HTML twin
    /// (PullRequest, Issue, Commit, Release, Discussion, WorkflowRun)
    /// after stripping the api host and pluralization-fixing /pulls/ and
    /// /commits/. For other types the path has no public HTML page:
    ///
    ///   • CheckSuite / CheckRun: /check-suites/<id> isn't browsable.
    ///   • Discussion: subject.url is sometimes null (discussions are
    ///     GraphQL-only on the notifications endpoint).
    ///
    /// Drive the decision off `subject.type` rather than substring-checking
    /// the rewritten URL — the previous check-for-api.github.com guard
    /// missed paths like /check-suites/123 that survive prefix-strip but
    /// 404 on github.com. Falls back to the repo's relevant tab so a click
    /// always lands somewhere meaningful. Marked `static` so it's
    /// reachable from tests.
    static func htmlURL(for n: GHNotification) -> URL? {
        let repoHTML = "https://github.com/\(n.repository.full_name)"

        // Only attempt the api → html rewrite for types whose API URL
        // shape maps to a public HTML page. Everything else falls
        // through to the per-type fallback below.
        let isRewriteable: Bool
        switch n.subject.type {
        case "PullRequest", "Issue", "Commit", "Release", "Discussion", "WorkflowRun":
            isRewriteable = true
        default:
            isRewriteable = false
        }
        if isRewriteable, let api = n.subject.url, !api.isEmpty {
            var s = api.replacingOccurrences(
                of: "https://api.github.com/repos/", with: "https://github.com/"
            )
            s = s.replacingOccurrences(of: "/pulls/", with: "/pull/")
            s = s.replacingOccurrences(of: "/commits/", with: "/commit/")
            // Defensive: if the prefix-strip didn't fire (URL came in a
            // shape we didn't expect for an otherwise-rewriteable type),
            // fall through rather than ship an api.github.com link.
            if !s.contains("api.github.com") {
                return URL(string: s)
            }
        }

        switch n.subject.type {
        case "Discussion":
            return URL(string: "\(repoHTML)/discussions")
        case "CheckSuite", "CheckRun", "WorkflowRun":
            return URL(string: "\(repoHTML)/actions")
        case "Release":
            return URL(string: "\(repoHTML)/releases")
        default:
            return URL(string: repoHTML)
        }
    }

    // MARK: Wire types

    struct GHNotification: Decodable {
        let id: String
        let unread: Bool
        let reason: String
        let updated_at: Date
        let subject: Subject
        let repository: Repo
        struct Subject: Decodable { let title: String; let type: String; let url: String? }
        struct Repo: Decodable { let full_name: String }
    }
}
