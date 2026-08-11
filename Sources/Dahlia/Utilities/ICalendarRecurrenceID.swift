import Foundation

/// RECURRENCE-ID をソース間で比較できる RFC 5545 形式へ正規化する。
enum ICalendarRecurrenceID {
    static let singleEvent = ""

    static func dateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }

    static func date(_ value: String) -> String? {
        let components = value.split(separator: "-", omittingEmptySubsequences: false)
        guard components.count == 3,
              components[0].count == 4,
              components[1].count == 2,
              components[2].count == 2,
              components.allSatisfy({ $0.allSatisfy(\.isNumber) })
        else { return nil }

        return components.joined()
    }

    static func date(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
    }
}
