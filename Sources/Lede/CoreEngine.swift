import Foundation
import Combine

@MainActor
final class CoreEngine: ObservableObject {
    @Published var digest: Digest?
    @Published var isRefreshing = false
    @Published var lastError: String?
    @Published var lastRefreshed: Date?

    private let storage: Storage
    private var minRefreshInterval: TimeInterval = 60

    init(storage: Storage) {
        self.storage = storage
        Task { self.digest = await storage.loadLastDigest() }
    }

    // MARK: Auth checks

    func hasClaudeCreds() -> Bool {
        Keychain.get(Keychain.Key.anthropicAPIKey) != nil ||
        Keychain.get(Keychain.Key.anthropicOAuthAccess) != nil
    }

    func hasAnySource() -> Bool {
        enabledSources().isEmpty == false
    }

    // MARK: Sources

    private func enabledSources() -> [NotificationSource] {
        let all: [NotificationSource] = [
            GitHubSource(),
            GmailSource(),
            SlackSource(),
            OutlookSource(),
        ]
        return all.filter { $0.isConfigured }
    }

    // MARK: Anthropic auth resolution

    private func anthropicClient() async -> AnthropicClient? {
        if let token = await ClaudeOAuth.validAccessToken() {
            return AnthropicClient(auth: .oauthBearer(accessToken: token))
        }
        if let key = Keychain.get(Keychain.Key.anthropicAPIKey) {
            return AnthropicClient(auth: .apiKey(key))
        }
        return nil
    }

    // MARK: Refresh

    func refreshIfConfigured() async {
        guard hasClaudeCreds(), hasAnySource() else { return }
        if let last = lastRefreshed, Date().timeIntervalSince(last) < minRefreshInterval { return }
        await refresh(force: false)
    }

    func refresh(force: Bool) async {
        if isRefreshing { return }
        isRefreshing = true
        lastError = nil
        defer { isRefreshing = false }

        guard let client = await anthropicClient() else {
            lastError = "No Claude credentials. Open Settings."
            return
        }

        let sources = enabledSources()
        if sources.isEmpty {
            lastError = "No sources configured. Open Settings."
            return
        }

        // Fetch all sources in parallel; ignore individual failures.
        var allItems: [RawItem] = []
        var sourceErrors: [String] = []
        await withTaskGroup(of: Result<[RawItem], Error>.self) { group in
            for s in sources {
                group.addTask {
                    do { return .success(try await s.fetch()) }
                    catch { return .failure(error) }
                }
            }
            for await result in group {
                switch result {
                case .success(let items): allItems.append(contentsOf: items)
                case .failure(let err): sourceErrors.append("\(err.localizedDescription)")
                }
            }
        }

        if allItems.isEmpty && !sourceErrors.isEmpty {
            lastError = sourceErrors.joined(separator: "\n")
            return
        }

        let pipeline = TriagePipeline(client: client, storage: storage)
        do {
            let digest = try await pipeline.run(items: allItems)
            self.digest = digest
            self.lastRefreshed = Date()
            if !sourceErrors.isEmpty {
                self.lastError = "Partial: " + sourceErrors.joined(separator: "; ")
            }
        } catch {
            self.lastError = error.localizedDescription
        }
    }
}
