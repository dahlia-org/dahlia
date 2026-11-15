import Foundation

enum AgentSchedule: Sendable, Equatable {
    case interval(TimeInterval)
    case calendar(weekdays: [Int], hour: Int, minute: Int)
    case once(Date)

    static func parse(_ value: String, now: Date = .now, calendar: Calendar = .current) throws -> Self {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let match = text.wholeMatch(of: /(?:every\s+)?(\d+(?:\.\d+)?)\s*(m|h|d|minutes?|hours?|days?)/) {
            let unit = String(match.2)
            let seconds = (Double(match.1) ?? 0) * (unit.hasPrefix("d") ? 86400 : unit.hasPrefix("h") ? 3600 : 60)
            guard seconds >= 900, seconds.isFinite,
                  seconds <= 31_536_000 else { throw HermesLearning.failure("Intervals must be between 15 minutes and one year.") }
            return .interval(seconds)
        }
        let normalized = text.replacingOccurrences(of: "every hour", with: "every 1h")
        if normalized != text { return try parse(normalized, now: now, calendar: calendar) }
        if let match = text
            .wholeMatch(
                of: /(?:every\s+)?(monday|tuesday|wednesday|thursday|friday|saturday|sunday|weekdays|day|daily)\s+(?:at\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)?/
            ) {
            var hour = Int(match.2) ?? -1
            let minute = match.3.flatMap { Int($0) } ?? 0
            if let period = match.4 {
                guard (1 ... 12).contains(hour) else { throw HermesLearning.failure("Invalid hour.") }
                hour = hour % 12 + (period == "pm" ? 12 : 0)
            }
            guard (0 ... 23).contains(hour), (0 ... 59).contains(minute) else { throw HermesLearning.failure("Invalid time.") }
            let days = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
            let weekdays = match.1 == "weekdays" ? [2, 3, 4, 5, 6] : days.firstIndex(of: String(match.1)).map { [$0 + 1] } ?? Array(1 ... 7)
            return .calendar(weekdays: weekdays, hour: hour, minute: minute)
        }
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: value), date > now { return .once(date) }
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.calendar = calendar
        local.timeZone = calendar.timeZone
        local.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        local.isLenient = false
        if let date = local.date(from: value), date > now { return .once(date) }
        local.dateFormat = "yyyy-MM-dd'T'HH:mm"
        if let date = local.date(from: value), date > now { return .once(date) }
        throw HermesLearning
            .failure(
                "Unsupported schedule. Use 30m, every 2h, every monday 9am, weekdays at 9am, or a future ISO datetime. Five-field cron expressions require an unavailable cron parser."
            )
    }

    func next(after date: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case let .interval(seconds): date.addingTimeInterval(seconds)
        case let .once(fire): fire > date ? fire : nil
        case let .calendar(weekdays, hour, minute):
            weekdays.compactMap { weekday in
                calendar.nextDate(
                    after: date,
                    matching: DateComponents(hour: hour, minute: minute, second: 0, weekday: weekday),
                    matchingPolicy: .nextTime
                )
            }.min()
        }
    }

    static func result(_ text: String) -> String {
        let lines = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines)
        if lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "[CRON_FAILURE]" { return "failed" }
        let silence = Set(["[SILENT]", "SILENT", "NO_REPLY", "NO REPLY"])
        if [lines.first, lines.last].compactMap(\.self)
            .contains(where: { silence.contains($0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()) }) { return "silent" }
        return "delivered"
    }
}
