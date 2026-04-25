import Foundation
import Combine

@MainActor
final class CoreEngine: ObservableObject {
    @Published var digest: Digest?
    @Published var isRefreshing = false
    /// True only while at least one Anthropic API call is in flight. Distinct
    /// from isRefreshing (which covers source HTTP fetches too) so the menu
    /// bar can show orange specifically for "talking to Claude" — most
    /// refreshes hit the triage cache and never call Claude at all.
    @Published var isCallingClaude = false
    @Published var lastError: String?
    @Published var lastRefreshed: Date?
    /// Health snapshot keyed by `Storage.stateKey(account:source:)`. Settings
    /// reads this; the panel doesn't.
    @Published var sourceStates: [String: SourceState] = [:]
    @Published var accounts: [Account] = []
    @Published var usage: UsageTotals = UsageTotals()

    private let storage: Storage
    private var minRefreshInterval: TimeInterval = 60
    private var backgroundTimer: Timer?
    /// Inflight count of Anthropic calls. The Bool published above tracks
    /// `counter > 0` so subscribers see clean on/off transitions even when
    /// multiple calls overlap (Sonnet during ongoing Haiku calls, etc.).
    private var claudeCallsInflight: Int = 0

    fileprivate func beginClaudeCall() {
        claudeCallsInflight += 1
        if !isCallingClaude { isCallingClaude = true }
    }

    fileprivate func endClaudeCall() {
        claudeCallsInflight = max(0, claudeCallsInflight - 1)
        if claudeCallsInflight == 0 { isCallingClaude = false }
    }

    init(storage: Storage, autoload: Bool = true) {
        self.storage = storage
        if autoload {
            Task {
                self.digest = await storage.loadLastDigest()
                self.sourceStates = await storage.allSourceStates()
                self.accounts = await storage.allAccounts()
                self.usage = await storage.currentUsage()
                await storage.runMaintenance()
            }
        }
    }

    func reloadAccounts() async {
        self.accounts = await storage.allAccounts()
        self.sourceStates = await storage.allSourceStates()
    }

    func disconnectAccount(_ account: Account) async {
        switch account.provider {
        case .github: GitHubOAuth.signOut(accountID: account.id)
        case .google: GoogleOAuth.signOut(accountID: account.id)
        case .microsoft: MicrosoftOAuth.signOut(accountID: account.id)
        case .slack: SlackOAuth.signOut(accountID: account.id)
        }
        await storage.removeAccount(account)
        await storage.clearSourceStates(forAccount: account)
        await reloadAccounts()
    }

    // MARK: Background refresh

    /// Fire `refreshIfConfigured` every `interval` seconds so the user gets
    /// fresh triages without keeping the panel open. Throttle inside
    /// `refreshIfConfigured` (minRefreshInterval) makes back-to-back calls cheap.
    /// Pass `nil` (or 0) to disable background refresh entirely.
    func startBackgroundRefresh(interval: TimeInterval? = nil) {
        backgroundTimer?.invalidate()
        backgroundTimer = nil
        let chosen = interval ?? configuredRefreshInterval()
        guard let chosen, chosen > 0 else { return }
        let timer = Timer(timeInterval: chosen, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                if Schedule.inQuietHours() && !Snooze.isActive {
                    Snooze.snooze(for: 60 * 60)  // re-arm every hour while quiet
                }
                await self.refreshIfConfigured()
            }
        }
        // Run on common modes so it keeps firing while menus / popups are up.
        RunLoop.main.add(timer, forMode: .common)
        backgroundTimer = timer
    }

    func stopBackgroundRefresh() {
        backgroundTimer?.invalidate()
        backgroundTimer = nil
    }

    /// Reads the user's preferred refresh cadence from UserDefaults.
    /// 0 = disabled.
    private func configuredRefreshInterval() -> TimeInterval? {
        let raw = UserDefaults.standard.double(forKey: "lede.refreshIntervalSeconds")
        if raw <= 0 {
            // Default 5 minutes if nothing set.
            return UserDefaults.standard.object(forKey: "lede.refreshIntervalSeconds") == nil ? 300 : nil
        }
        return raw
    }

    // MARK: Auth checks

    func hasClaudeCreds() -> Bool {
        if Keychain.get(Keychain.Key.anthropicAPIKey) != nil { return true }
        if AppConfig.shared.enableSubscriptionOAuth,
           Keychain.get(Keychain.Key.anthropicOAuthAccess) != nil { return true }
        return false
    }

    func hasAnySource() -> Bool {
        accounts.isEmpty == false
    }

    // MARK: Sources

    /// Build the per-(account, source) NotificationSource impls for everything
    /// configured + enabled. One Account expands into multiple Sources when the
    /// provider supports them (Google → Gmail + Calendar, Microsoft → Outlook
    /// + Calendar).
    private func notificationSources(for accountList: [Account]) -> [NotificationSource] {
        var out: [NotificationSource] = []
        for account in accountList {
            for source in account.provider.sources {
                guard source.isEnabledByUser else { continue }
                let s: NotificationSource
                switch (account.provider, source) {
                case (.github, .github): s = GitHubSource(account: account)
                case (.google, .gmail): s = GmailSource(account: account)
                case (.google, .calendar): s = GoogleCalendarSource(account: account)
                case (.microsoft, .outlook): s = OutlookSource(account: account)
                case (.microsoft, .calendar): s = OutlookCalendarSource(account: account)
                case (.slack, .slack): s = SlackSource(account: account)
                default: continue
                }
                if s.isConfigured { out.append(s) }
            }
        }
        return out
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

        // Re-read accounts every refresh in case the user just added one.
        let accountList = await storage.allAccounts()
        self.accounts = accountList
        let sources = notificationSources(for: accountList)
        if sources.isEmpty {
            lastError = "No sources configured. Open Settings."
            Log.warn("refresh aborted: no sources configured")
            return
        }

        let names = sources.map { "\($0.source.rawValue)[\($0.account.label)]" }.joined(separator: ",")
        Log.info("fetching from \(sources.count) source(s): \(names)")

        // Fetch all (account, source) pairs in parallel; ignore individual failures.
        var allItems: [RawItem] = []
        var sourceErrors: [String] = []
        await withTaskGroup(of: (Account, Source, Result<[RawItem], Error>).self) { group in
            for s in sources {
                group.addTask {
                    do { return (s.account, s.source, .success(try await s.fetch())) }
                    catch { return (s.account, s.source, .failure(error)) }
                }
            }
            for await (account, src, result) in group {
                let key = Storage.stateKey(account: account, source: src)
                switch result {
                case .success(let items):
                    Log.info("\(src.rawValue)[\(account.label)]: fetched \(items.count) item(s)")
                    allItems.append(contentsOf: items)
                    let state = SourceState(lastFetchedAt: Date(), lastItemCount: items.count, lastError: nil)
                    await storage.setSourceState(account: account, source: src, state: state)
                    sourceStates[key] = state
                case .failure(let err):
                    Log.error("\(src.rawValue)[\(account.label)]: fetch failed — \(err.localizedDescription)")
                    sourceErrors.append("\(account.label) · \(err.localizedDescription)")
                    var state = sourceStates[key] ?? SourceState()
                    state.lastError = err.localizedDescription
                    state.lastFetchedAt = Date()
                    await storage.setSourceState(account: account, source: src, state: state)
                    sourceStates[key] = state
                }
            }
        }

        Log.info("fetched \(allItems.count) total item(s) across all sources")

        if allItems.isEmpty && !sourceErrors.isEmpty {
            lastError = sourceErrors.joined(separator: "\n")
            return
        }

        // Closures hop to MainActor since CoreEngine is @MainActor; the
        // pipeline itself runs from whatever Task drives client.complete().
        // `guard let self` first so the inner Task captures a `let` —
        // Swift 6 strict concurrency rejects capturing the outer
        // `[weak self]` var across the concurrent Task boundary.
        let pipeline = TriagePipeline(
            client: client,
            storage: storage,
            onClaudeCallStart: { [weak self] in
                guard let self else { return }
                Task { @MainActor in self.beginClaudeCall() }
            },
            onClaudeCallEnd: { [weak self] in
                guard let self else { return }
                Task { @MainActor in self.endClaudeCall() }
            }
        )
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
