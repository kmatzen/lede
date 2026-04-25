import Foundation
import Combine

@MainActor
final class CoreEngine: ObservableObject {
    @Published var digest: Digest?
    @Published var isRefreshing = false
    @Published var lastError: String?
    @Published var lastRefreshed: Date?
    @Published var sourceStates: [Source: SourceState] = [:]
    @Published var usage: UsageTotals = UsageTotals()

    private let storage: Storage
    private var minRefreshInterval: TimeInterval = 60
    private var backgroundTimer: Timer?

    init(storage: Storage) {
        self.storage = storage
        Task {
            self.digest = await storage.loadLastDigest()
            self.sourceStates = await storage.allSourceStates()
            self.usage = await storage.currentUsage()
        }
    }

    // MARK: Background refresh

    /// Fire `refreshIfConfigured` every `interval` seconds so the user gets
    /// fresh triages without keeping the panel open. Throttle inside
    /// `refreshIfConfigured` (minRefreshInterval) makes back-to-back calls cheap.
    func startBackgroundRefresh(interval: TimeInterval = 300) {
        backgroundTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshIfConfigured() }
        }
        // Run on common modes so it keeps firing while menus / popups are up.
        RunLoop.main.add(timer, forMode: .common)
        backgroundTimer = timer
    }

    func stopBackgroundRefresh() {
        backgroundTimer?.invalidate()
        backgroundTimer = nil
    }

    // MARK: Auth checks

    func hasClaudeCreds() -> Bool {
        if Keychain.get(Keychain.Key.anthropicAPIKey) != nil { return true }
        if AppConfig.shared.enableSubscriptionOAuth,
           Keychain.get(Keychain.Key.anthropicOAuthAccess) != nil { return true }
        return false
    }

    func hasAnySource() -> Bool {
        enabledSources().isEmpty == false
    }

    // MARK: Sources

    private func enabledSources() -> [NotificationSource] {
        let all: [NotificationSource] = [
            GitHubSource(),
            GmailSource(),
            GoogleCalendarSource(),
            SlackSource(),
            OutlookSource(),
            OutlookCalendarSource(),
        ]
        return all.filter { $0.isConfigured }
    }

    // MARK: Anthropic auth resolution

    private func anthropicClient() async -> AnthropicClient? {
        if AppConfig.shared.enableSubscriptionOAuth,
           let token = await ClaudeOAuth.validAccessToken() {
            return AnthropicClient(auth: .oauthBearer(accessToken: token))
        }
        if let key = Keychain.get(Keychain.Key.anthropicAPIKey) {
            return AnthropicClient(auth: .apiKey(key))
        }
        return nil
    }

    // MARK: Dismiss

    func dismiss(_ hash: String) async {
        await storage.dismiss(hash)
        // Remove from the current digest for instant UI feedback.
        guard let current = digest else { return }
        let remaining = current.items.filter { $0.contentHash != hash }
        let updated = Digest(
            generatedAt: current.generatedAt,
            items: remaining,
            synthesis: current.synthesis
        )
        digest = updated
        await storage.saveDigest(updated)
    }

    func dismissCount() async -> Int {
        await storage.allDismissed().count
    }

    func clearDismissals() async {
        await storage.clearDismissals()
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

        Log.info("refresh start force=\(force)")

        guard let client = await anthropicClient() else {
            lastError = "No Claude credentials. Open Settings."
            Log.warn("refresh aborted: no Claude credentials")
            return
        }

        let sources = enabledSources()
        if sources.isEmpty {
            lastError = "No sources configured. Open Settings."
            Log.warn("refresh aborted: no sources configured")
            return
        }

        let names = sources.map { $0.source.rawValue }.joined(separator: ",")
        Log.info("fetching from \(sources.count) source(s): \(names)")

        // Fetch all sources in parallel; ignore individual failures.
        var allItems: [RawItem] = []
        var sourceErrors: [String] = []
        await withTaskGroup(of: (Source, Result<[RawItem], Error>).self) { group in
            for s in sources {
                group.addTask {
                    do { return (s.source, .success(try await s.fetch())) }
                    catch { return (s.source, .failure(error)) }
                }
            }
            for await (src, result) in group {
                switch result {
                case .success(let items):
                    Log.info("\(src.rawValue): fetched \(items.count) item(s)")
                    allItems.append(contentsOf: items)
                    let state = SourceState(lastFetchedAt: Date(), lastItemCount: items.count, lastError: nil)
                    await storage.setSourceState(src, state: state)
                    sourceStates[src] = state
                case .failure(let err):
                    Log.error("\(src.rawValue): fetch failed — \(err.localizedDescription)")
                    sourceErrors.append("\(err.localizedDescription)")
                    var state = sourceStates[src] ?? SourceState()
                    state.lastError = err.localizedDescription
                    state.lastFetchedAt = Date()
                    await storage.setSourceState(src, state: state)
                    sourceStates[src] = state
                }
            }
        }

        Log.info("fetched \(allItems.count) total item(s) across all sources")

        if allItems.isEmpty && !sourceErrors.isEmpty {
            lastError = sourceErrors.joined(separator: "\n")
            return
        }

        let pipeline = TriagePipeline(client: client, storage: storage)
        do {
            let digest = try await pipeline.run(items: allItems)
            self.digest = digest
            self.lastRefreshed = Date()
            self.usage = await storage.currentUsage()
            Log.info("digest built: \(digest.items.count) item(s) visible")
            await Notifier.notifyNewItems(digest.items, storage: storage)
            if !sourceErrors.isEmpty {
                self.lastError = "Partial: " + sourceErrors.joined(separator: "; ")
            }
        } catch {
            Log.error("pipeline failed: \(error.localizedDescription)")
            self.lastError = error.localizedDescription
        }
    }
}
