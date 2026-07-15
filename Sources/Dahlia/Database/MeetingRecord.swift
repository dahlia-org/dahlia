import Foundation
import GRDB

/// ミーティングの状態。
enum MeetingStatus: String, Codable, DatabaseValueConvertible {
    case transcriptNotFound = "TRANSCRIPT_NOT_FOUND"
    case processingTranscript = "PROCESSING_TRANSCRIPT"
    case ready = "READY"

    static func fromDatabaseValue(_ dbValue: DatabaseValue) -> MeetingStatus? {
        guard let rawValue = String.fromDatabaseValue(dbValue),
              let status = normalized(rawValue: rawValue)
        else {
            return nil
        }
        return status
    }

    var databaseValue: DatabaseValue {
        rawValue.databaseValue
    }

    private static func normalized(rawValue: String) -> MeetingStatus? {
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "TRANSCRIPT_NOT_FOUND":
            .transcriptNotFound
        case "PROCESSING_TRANSCRIPT":
            .processingTranscript
        case "READY", "RECORDING":
            .ready
        default:
            nil
        }
    }
}

/// ミーティングセッションを表す GRDB レコード。
struct MeetingRecord: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "meetings"

    var id: UUID
    var vaultId: UUID
    var projectId: UUID?
    var name: String
    var description = ""
    var status: MeetingStatus = .transcriptNotFound
    var duration: TimeInterval?
    var createdAt: Date
    var updatedAt: Date
    var calendarEventIcalUid: String? = nil
    var calendarEventRecurrenceId: String? = nil

    enum CodingKeys: String, CodingKey {
        case id
        case vaultId
        case projectId
        case name
        case description
        case status
        case duration
        case createdAt
        case updatedAt
        case calendarEventIcalUid = "calendar_event_ical_uid"
        case calendarEventRecurrenceId = "calendar_event_recurrence_id"
    }
}

extension MeetingRecord {
    /// 明示指定がなければ、同じ iCalendar 系列の現在以前の予定から直近の project を引き継ぐ。
    static func resolvedProjectIdForNewMeeting(
        requestedProjectId: UUID?,
        calendarEvent: CalendarEvent?,
        vaultId: UUID,
        allowsCalendarSeriesProjectInheritance: Bool = true,
        in db: Database
    ) throws -> UUID? {
        if let requestedProjectId {
            return requestedProjectId
        }
        guard allowsCalendarSeriesProjectInheritance else { return nil }
        guard let calendarEvent,
              let icalUid = calendarEvent.key?.icalUid else { return nil }

        return try UUID.fetchOne(
            db,
            sql: """
            SELECT projects.id
            FROM meetings
            JOIN calendar_events
              ON calendar_events.ical_uid = meetings.calendar_event_ical_uid
             AND calendar_events.recurrence_id = meetings.calendar_event_recurrence_id
            JOIN projects ON projects.id = meetings.projectId
            WHERE meetings.vaultId = ?
              AND projects.vaultId = ?
              AND projects.missingOnDisk = 0
              AND meetings.calendar_event_ical_uid = ?
              AND calendar_events.start <= ?
            ORDER BY calendar_events.start DESC, meetings.createdAt DESC, meetings.id DESC
            LIMIT 1
            """,
            arguments: [vaultId, vaultId, icalUid, calendarEvent.startDate]
        )
    }
}
