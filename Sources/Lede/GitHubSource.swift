import Foundation

/// Reads notifications using whichever credential is stored under the account
/// (OAuth bearer from device flow, or a personal access token saved manually).
struct GitHubSource: NotificationSource {
    let account: Account
    let source: Source = .github

    var isConfigured: Bool {
        GitHubOAuth.token(forAccount: account.id) != nil
    }

    func fetch() async throws -> [RawItem] {
        guard let token = GitHubOAuth.token(forAccount: account.id) else { return [] }

        var req = URLRequest(url: URL(string: "https://api.github.com/notifications?per_page=50&all=false")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("Lede/0.1", forHTTPHeaderField: "User-Agent")

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw SourceError(source: source, message: "HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0) \(body.prefix(200))")
        }
        let notifs = try JSONDecoder.iso.decode([GHNotification].self, from: data)
        let acct = account
        return notifs.compactMap { n in
            let url = n.subject.url.flatMap(htmlURL)
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
    }

    /// GH notification subject URLs are API URLs. Convert to the user-facing HTML URL best-effort.
    private func htmlURL(_ api: String) -> URL? {
        var s = api
        s = s.replacingOccurrences(of: "https://api.github.com/repos/", with: "https://github.com/")
        s = s.replacingOccurrences(of: "/pulls/", with: "/pull/")
        s = s.replacingOccurrences(of: "/commits/", with: "/commit/")
        return URL(string: s)
    }

    // MARK: Wire types

    private struct GHNotification: Decodable {
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
