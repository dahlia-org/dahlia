import Foundation

enum BatchAudioRetentionPeriod: Int, CaseIterable, Identifiable, Sendable {
    case forever = 0
    case oneDay = 1
    case threeDays = 3
    case sevenDays = 7
    case fourteenDays = 14

    static let defaultValue: Self = .threeDays

    var id: Int { rawValue }

    var displayName: String {
        self == .forever ? L10n.forever : L10n.days(rawValue)
    }

    var retentionInterval: TimeInterval? {
        self == .forever ? nil : TimeInterval(rawValue * 24 * 60 * 60)
    }

    func isShorter(than other: Self) -> Bool {
        if self == .forever { return false }
        return other == .forever || rawValue < other.rawValue
    }

    static func resolved(rawValue: Int) -> Self {
        Self(rawValue: rawValue) ?? defaultValue
    }
}
