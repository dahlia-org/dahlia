import Foundation

/// Device-local minimum retention. Zero means originals are kept indefinitely.
public enum ServerContentRetention {
    public static let defaultsKey = "serverContentRetentionDays"
    public static let defaultDays = 0

    public static func days(in defaults: UserDefaults = .standard) -> Int {
        guard let days = defaults.object(forKey: defaultsKey) as? Int, days >= 0 else { return defaultDays }
        return days
    }

    public static func allowsEviction(lastUsedAt: Date?, now: Date, days: Int) -> Bool {
        guard days > 0, let lastUsedAt else { return false }
        return now.timeIntervalSince(lastUsedAt) >= Double(days) * 86400
    }
}
