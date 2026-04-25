import Foundation

protocol NotificationSource {
    var account: Account { get }
    var source: Source { get }
    var isConfigured: Bool { get }
    /// Returns recent items (caller will cap + dedupe).
    func fetch() async throws -> [RawItem]
}

struct SourceError: Error, LocalizedError {
    let source: Source
    let message: String
    var errorDescription: String? { "\(source.displayName): \(message)" }
}
