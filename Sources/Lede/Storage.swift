import Foundation

/// Disk-backed cache of per-item triages, keyed by content hash.
/// We never re-call the model for a hash we've already triaged — this is the main token saving.
actor Storage {
    static let shared: Storage = {
        do { return try Storage() } catch { fatalError("Storage init: \(error)") }
    }()

    private let cacheURL: URL
    private let digestURL: URL
    private let dismissedURL: URL
    private let notifiedURL: URL
    private let sourceStateURL: URL
    private let accountsURL: URL
    private let usageURL: URL
    private var triages: [String: ItemTriage] = [:]
    private var dismissed: Set<String> = []
    private var notified: Set<String> = []
    /// Per-(account, source) health snapshot. Key is `Storage.stateKey`.
    private var sourceStates: [String: SourceState] = [:]
    private var accounts: AccountsRegistry = AccountsRegistry()
    private var usage: UsageTotals = UsageTotals()

    init() throws {
        let fm = FileManager.default
        let support = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                 appropriateFor: nil, create: true)
        let dir = support.appendingPathComponent("Lede", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.cacheURL = dir.appendingPathComponent("triage_cache.json")
        self.digestURL = dir.appendingPathComponent("last_digest.json")
        self.dismissedURL = dir.appendingPathComponent("dismissed.json")
        self.notifiedURL = dir.appendingPathComponent("notified.json")
        self.sourceStateURL = dir.appendingPathComponent("source_state.json")
        self.accountsURL = dir.appendingPathComponent("accounts.json")
        self.usageURL = dir.appendingPathComponent("usage.json")

        if let data = try? Data(contentsOf: cacheURL),
           let decoded = try? JSONDecoder.iso.decode([String: ItemTriage].self, from: data) {
            self.triages = decoded
        }
        if let data = try? Data(contentsOf: dismissedURL),
           let decoded = try? JSONDecoder.iso.decode([String].self, from: data) {
            self.dismissed = Set(decoded)
        }
        if let data = try? Data(contentsOf: notifiedURL),
           let decoded = try? JSONDecoder.iso.decode([String].self, from: data) {
            self.notified = Set(decoded)
        }
        if let data = try? Data(contentsOf: sourceStateURL),
           let decoded = try? JSONDecoder.iso.decode([String: SourceState].self, from: data) {
            self.sourceStates = decoded
        }
        if let data = try? Data(contentsOf: accountsURL),
           let decoded = try? JSONDecoder.iso.decode(AccountsRegistry.self, from: data) {
            self.accounts = decoded
        }
        if let data = try? Data(contentsOf: usageURL),
           let decoded = try? JSONDecoder.iso.decode(UsageTotals.self, from: data) {
            self.usage = decoded
        }
    }

    func getTriage(for hash: String) -> ItemTriage? { triages[hash] }

    func putTriage(_ t: ItemTriage) {
        triages[t.contentHash] = t
        save()
    }

    func putTriages(_ ts: [ItemTriage]) {
        for t in ts { triages[t.contentHash] = t }
        save()
    }

    /// Drop triages we haven't seen referenced in a long time.
    func prune(olderThan days: Int) {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        triages = triages.filter { $0.value.createdAt > cutoff }
        save()
    }

    /// One call that prunes all the rolling stores by age. Called on launch +
    /// periodically by the engine so disk usage stays bounded.
    func runMaintenance() {
        let now = Date()
        let triageTTL: TimeInterval = 30 * 86400
        let stateTTL: TimeInterval = 14 * 86400

        // Triages — drop entries older than 30 days.
        let triageCutoff = now.addingTimeInterval(-triageTTL)
        let triagesBefore = triages.count
        triages = triages.filter { $0.value.createdAt > triageCutoff }
        if triagesBefore != triages.count {
            save()
        }

        // Notified set: we don't track timestamps per hash, so cap the set
        // size instead. 5000 is plenty of buffer; older items just risk
        // re-notifying once each, which is fine.
        if notified.count > 5000 {
            notified = Set(notified.suffix(5000))
            saveNotified()
        }

        // Drop SourceStates we haven't seen in 2 weeks (typically because the
        // user disconnected the account/source — its dictionary entry sticks
        // around until we sweep it).
        let stateCutoff = now.addingTimeInterval(-stateTTL)
        let statesBefore = sourceStates.count
        sourceStates = sourceStates.filter { _, state in
            (state.lastFetchedAt ?? .distantPast) > stateCutoff
        }
        if statesBefore != sourceStates.count {
            saveSourceStates()
        }
    }

    func loadLastDigest() -> Digest? {
        guard let data = try? Data(contentsOf: digestURL) else { return nil }
        return try? JSONDecoder.iso.decode(Digest.self, from: data)
    }

    func saveDigest(_ d: Digest) {
        guard let data = try? JSONEncoder.iso.encode(d) else { return }
        try? data.write(to: digestURL, options: .atomic)
    }

    // MARK: - Dismissals

    func allDismissed() -> Set<String> { dismissed }

    func dismiss(_ hash: String) {
        dismissed.insert(hash)
        saveDismissed()
    }

    func clearDismissals() {
        dismissed.removeAll()
        saveDismissed()
    }

    private func saveDismissed() {
        guard let data = try? JSONEncoder.iso.encode(Array(dismissed)) else { return }
        try? data.write(to: dismissedURL, options: .atomic)
    }

    // MARK: - Notification de-dupe

    func allNotified() -> Set<String> { notified }

    func markNotified(_ hash: String) {
        notified.insert(hash)
        saveNotified()
    }

    private func saveNotified() {
        guard let data = try? JSONEncoder.iso.encode(Array(notified)) else { return }
        try? data.write(to: notifiedURL, options: .atomic)
    }

    // MARK: - Source health

    /// Composite key for `(account, source)` so each account's per-source
    /// status is tracked independently. Used as the dict key for sourceStates.
    static func stateKey(account: Account, source: Source) -> String {
        "\(account.key):\(source.rawValue)"
    }

    func allSourceStates() -> [String: SourceState] { sourceStates }

    func sourceState(account: Account, source: Source) -> SourceState? {
        sourceStates[Self.stateKey(account: account, source: source)]
    }

    func setSourceState(account: Account, source: Source, state: SourceState) {
        sourceStates[Self.stateKey(account: account, source: source)] = state
        saveSourceStates()
    }

    /// Drop every state row for a given account — called when the account is
    /// disconnected.
    func clearSourceStates(forAccount account: Account) {
        let prefix = account.key + ":"
        sourceStates = sourceStates.filter { !$0.key.hasPrefix(prefix) }
        saveSourceStates()
    }

    private func saveSourceStates() {
        if let data = try? JSONEncoder.iso.encode(sourceStates) {
            try? data.write(to: sourceStateURL, options: .atomic)
        }
    }

    // MARK: - Accounts registry

    func allAccounts() -> [Account] { accounts.accounts }

    func accounts(forProvider provider: Provider) -> [Account] {
        accounts.accounts.filter { $0.provider == provider }
    }

    func account(matchingKey key: String) -> Account? {
        accounts.accounts.first { $0.key == key }
    }

    /// Insert or update by Account.key. Existing entries are replaced so an
    /// account's label can be refreshed by re-adding it.
    func upsertAccount(_ account: Account) {
        if let idx = accounts.accounts.firstIndex(where: { $0.key == account.key }) {
            accounts.accounts[idx] = account
        } else {
            accounts.accounts.append(account)
        }
        saveAccounts()
    }

    func removeAccount(_ account: Account) {
        accounts.accounts.removeAll { $0.key == account.key }
        saveAccounts()
    }

    private func saveAccounts() {
        if let data = try? JSONEncoder.iso.encode(accounts) {
            try? data.write(to: accountsURL, options: .atomic)
        }
    }

    // MARK: - Usage totals

    func currentUsage() -> UsageTotals { usage }

    /// Add to the running total. Resets the counter when the calendar month
    /// rolls over so users see "this month" not "since install".
    func addUsage(model: String, input: Int, output: Int, cacheReads: Int, cacheWrites: Int) {
        let key = monthKey()
        if usage.monthKey != key {
            usage = UsageTotals(monthKey: key)
        }
        var entry = usage.byModel[model] ?? ModelUsage()
        entry.inputTokens += input
        entry.outputTokens += output
        entry.cacheReads += cacheReads
        entry.cacheWrites += cacheWrites
        usage.byModel[model] = entry
        if let data = try? JSONEncoder.iso.encode(usage) {
            try? data.write(to: usageURL, options: .atomic)
        }
    }

    private func monthKey(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }

    private func save() {
        guard let data = try? JSONEncoder.iso.encode(triages) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }
}

extension JSONEncoder {
    static let iso: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}
extension JSONDecoder {
    static let iso: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
