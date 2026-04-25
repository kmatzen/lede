import Foundation

/// Quiet-hours scheduler. The user picks a daily window; while we're in it,
/// notifications are suppressed (via Snooze) but background fetches keep
/// running so the panel stays accurate when opened.
///
/// Stored as two integer hours in UserDefaults:
///   `lede.quietStartHour` (0–23, inclusive)
///   `lede.quietEndHour`   (0–23, exclusive)
///
/// `quietEnabled` defaults to false. Wrap-around windows (e.g. 22→7) work.
enum Schedule {
    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "lede.quietEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "lede.quietEnabled") }
    }
    static var startHour: Int {
        get { UserDefaults.standard.object(forKey: "lede.quietStartHour") as? Int ?? 22 }
        set { UserDefaults.standard.set(newValue, forKey: "lede.quietStartHour") }
    }
    static var endHour: Int {
        get { UserDefaults.standard.object(forKey: "lede.quietEndHour") as? Int ?? 7 }
        set { UserDefaults.standard.set(newValue, forKey: "lede.quietEndHour") }
    }

    static func inQuietHours(now: Date = Date()) -> Bool {
        guard enabled else { return false }
        let cal = Calendar.current
        let hour = cal.component(.hour, from: now)
        let s = startHour, e = endHour
        if s == e { return false }
        if s < e { return hour >= s && hour < e }
        // Wrap-around: e.g. 22..<24 || 0..<7
        return hour >= s || hour < e
    }
}
