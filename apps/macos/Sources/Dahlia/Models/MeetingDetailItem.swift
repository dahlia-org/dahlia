import Foundation
import GRDB

/// 選択中のミーティング詳細に必要なメタデータだけを保持する軽量 projection。
struct MeetingDetailItem: Equatable, FetchableRecord, Identifiable {
    var meetingId: UUID
    var vaultId: UUID
    var projectId: UUID?
    var projectName: String?
    var meetingName: String
    var meetingDescription: String
    var status: MeetingStatus
    var duration: TimeInterval?
    var createdAt: Date
    var recordingStartedAt: Date?
    var hasSummary: Bool
    var tags: [TagInfo]
    var calendarEvent: CalendarEventDisplayInfo?

    var id: UUID { meetingId }

    var effectiveRecordingStartedAt: Date {
        recordingStartedAt ?? createdAt
    }

    private static let fieldSeparator: Character = "\u{1E}"
    private static let recordSeparator: Character = "\u{1F}"

    init(row: Row) throws {
        meetingId = row["meetingId"]
        vaultId = row["vaultId"]
        projectId = row["projectId"]
        projectName = row["projectName"]
        meetingName = row["meetingName"]
        meetingDescription = row["meetingDescription"]
        status = row["status"]
        duration = row["duration"]
        createdAt = row["createdAt"]
        recordingStartedAt = row["recordingStartedAt"]
        hasSummary = row["hasSummary"]
        tags = Self.decodeTags(row["tags"])

        let calendarEventTitle: String? = row["calendarEventTitle"]
        let calendarEventDescription: String? = row["calendarEventDescription"]
        let calendarEventStart: Date? = row["calendarEventStart"]
        let calendarEventEnd: Date? = row["calendarEventEnd"]
        let calendarEventIsAllDay: Bool? = row["calendarEventIsAllDay"]
        if let calendarEventTitle,
           let calendarEventDescription,
           let calendarEventStart,
           let calendarEventEnd,
           let calendarEventIsAllDay {
            calendarEvent = CalendarEventDisplayInfo(
                title: calendarEventTitle,
                description: calendarEventDescription,
                startDate: calendarEventStart,
                endDate: calendarEventEnd,
                isAllDay: calendarEventIsAllDay
            )
        } else {
            calendarEvent = nil
        }
    }

    private static func decodeTags(_ value: String?) -> [TagInfo] {
        guard let value, !value.isEmpty else { return [] }
        return value.split(separator: recordSeparator, omittingEmptySubsequences: false).compactMap { entry in
            let parts = entry.split(separator: fieldSeparator, maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            return TagInfo(name: String(parts[0]), colorHex: String(parts[1]))
        }
    }
}
