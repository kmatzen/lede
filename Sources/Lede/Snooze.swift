import Foundation

/// Snooze suppresses notifications + dims the menu-bar badge until a
/// specific Date. Fetches keep running so the panel stays accurate when
/// the user actively opens it.
enum Snooze {
    private static let key = "lede.snoozeUntil"

    static var until: Date? {
        let ts = UserDefaults.standard.double(forKey: key)
        if ts <= 0 { return nil }
        let date = Date(timeIntervalSince1970: ts)
        // Auto-clear when the deadline has passed so callers don't have to
        // remember to compare.
        if date <= Date() {
            UserDefaults.standard.removeObject(forKey: key)
            return nil
        }
        return date
    }

    static var isActive: Bool { until != nil }

    static func snooze(for interval: TimeInterval) {
        let date = Date().addingTimeInterval(interval)
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: key)
        NotificationCenter.default.post(name: .ledeSnoozeChanged, object: nil)
    }

    static func snoozeUntilTomorrowMorning() {
        var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        components.day! += 1
        components.hour = 8
        components.minute = 0
        let date = Calendar.current.date(from: components) ?? Date().addingTimeInterval(8 * 3600)
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: key)
        NotificationCenter.default.post(name: .ledeSnoozeChanged, object: nil)
    }

    static func wake() {
        UserDefaults.standard.removeObject(forKey: key)
        NotificationCenter.default.post(name: .ledeSnoozeChanged, object: nil)
    }
}

extension Notification.Name {
    static let ledeSnoozeChanged = Notification.Name("lede.snooze-changed")
}
