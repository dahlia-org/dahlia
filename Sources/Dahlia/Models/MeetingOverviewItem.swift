import Foundation
import GRDB

/// Meetings ワークスペースに表示する一覧用の集約モデル。
struct MeetingOverviewItem: Equatable, FetchableRecord, Identifiable {
    var meetingId: UUID
    var vaultId: UUID
    var projectId: UUID?
    var projectName: String?
    var meetingName: String
    var meetingDescription: String
    var status: MeetingStatus
    var duration: TimeInterval?
    var createdAt: Date
    var hasSummary: Bool
    var segmentCount: Int
    var latestSegmentText: String?
    var tags: [TagInfo]
    var calendarEvent: CalendarEventDisplayInfo?

    var id: UUID { meetingId }

    /// レコードセパレータ (name/colorHex 間) とユニットセパレータ (タグ間) の区切り文字。
    private static let fieldSeparator: Character = "\u{1E}"
    private static let recordSeparator: Character = "\u{1F}"

    init(
        meetingId: UUID,
        vaultId: UUID,
        projectId: UUID?,
        projectName: String?,
        meetingName: String,
        meetingDescription: String = "",
        status: MeetingStatus,
        duration: TimeInterval?,
        createdAt: Date,
        hasSummary: Bool,
        segmentCount: Int,
        latestSegmentText: String?,
        tags: [TagInfo],
        calendarEvent: CalendarEventDisplayInfo? = nil
    ) {
        self.meetingId = meetingId
        self.vaultId = vaultId
        self.projectId = projectId
        self.projectName = projectName
        self.meetingName = meetingName
        self.meetingDescription = meetingDescription
        self.status = status
        self.duration = duration
        self.createdAt = createdAt
        self.hasSummary = hasSummary
        self.segmentCount = segmentCount
        self.latestSegmentText = latestSegmentText
        self.tags = tags
        self.calendarEvent = calendarEvent
    }

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
        hasSummary = row["hasSummary"]
        segmentCount = row["segmentCount"]
        latestSegmentText = row["latestSegmentText"]

        // GROUP_CONCAT(t.name || X'1E' || t.colorHex, X'1F') をパース
        if let tagString: String = row["tags"], !tagString.isEmpty {
            tags = tagString.split(separator: Self.recordSeparator, omittingEmptySubsequences: false).compactMap { entry in
                let parts = entry.split(separator: Self.fieldSeparator, maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { return nil }
                return TagInfo(name: String(parts[0]), colorHex: String(parts[1]))
            }
        } else {
            tags = []
        }

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

    var meeting: MeetingRecord {
        MeetingRecord(
            id: meetingId,
            vaultId: vaultId,
            projectId: projectId,
            name: meetingName,
            description: meetingDescription,
            status: status,
            duration: duration,
            createdAt: createdAt,
            updatedAt: createdAt
        )
    }
}
