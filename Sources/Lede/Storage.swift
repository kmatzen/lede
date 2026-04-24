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
    private var triages: [String: ItemTriage] = [:]
    private var dismissed: Set<String> = []

    init() throws {
        let fm = FileManager.default
        let support = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                 appropriateFor: nil, create: true)
        let dir = support.appendingPathComponent("Lede", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.cacheURL = dir.appendingPathComponent("triage_cache.json")
        self.digestURL = dir.appendingPathComponent("last_digest.json")
        self.dismissedURL = dir.appendingPathComponent("dismissed.json")

        if let data = try? Data(contentsOf: cacheURL),
           let decoded = try? JSONDecoder.iso.decode([String: ItemTriage].self, from: data) {
            self.triages = decoded
        }
        if let data = try? Data(contentsOf: dismissedURL),
           let decoded = try? JSONDecoder.iso.decode([String].self, from: data) {
            self.dismissed = Set(decoded)
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
