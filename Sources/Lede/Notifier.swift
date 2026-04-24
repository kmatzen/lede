import Foundation
import UserNotifications

/// Posts a macOS Notification Center banner the first time we see a
/// high-priority item. Each item is notified at most once (tracked by
/// content hash in Storage so the dedupe survives relaunches).
///
/// Thresholds:
///   score >= 9 → notify, sound on
///   score >= 7 → notify silently (or skip — keep it bounded)
enum Notifier {
    private static var didRequestAuth = false

    static func requestAuthIfNeeded() async {
        guard !didRequestAuth else { return }
        didRequestAuth = true
        let center = UNUserNotificationCenter.current()
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    /// Post banners for any items above the threshold that haven't been
    /// notified yet. Updates Storage's "notified" set so re-runs are no-ops.
    static func notifyNewItems(_ items: [Digest.Item], storage: Storage) async {
        let threshold = 9
        let already = await storage.allNotified()
        let candidates = items.filter { $0.score >= threshold && !already.contains($0.contentHash) }
        guard !candidates.isEmpty else { return }

        await requestAuthIfNeeded()
        let center = UNUserNotificationCenter.current()

        for item in candidates {
            let content = UNMutableNotificationContent()
            content.title = "[\(item.source.displayName)] \(item.title)"
            content.body = item.summary
            if let sender = item.sender { content.subtitle = sender }
            content.sound = .default
            // Stash url so a future click handler can open it.
            if let url = item.url?.absoluteString { content.userInfo["url"] = url }
            let req = UNNotificationRequest(
                identifier: "lede.\(item.contentHash)",
                content: content,
                trigger: nil
            )
            try? await center.add(req)
            await storage.markNotified(item.contentHash)
            Log.info("notified \(item.source.rawValue) score=\(item.score) hash=\(item.contentHash.prefix(8))")
        }
    }
}
