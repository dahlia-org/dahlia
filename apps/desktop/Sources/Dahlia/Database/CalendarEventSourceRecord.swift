import Foundation
import GRDB

struct CalendarEventSourceRecord: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "calendar_event_sources"

    var platform: String
    var calendarId: String
    var platformId: String
    var icalUid: String
    var recurrenceId: String
    var createdAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case platform
        case calendarId = "calendar_id"
        case platformId = "platform_id"
        case icalUid = "ical_uid"
        case recurrenceId = "recurrence_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(now: Date, event: CalendarEvent, key: CalendarEventKey) {
        platform = event.platform
        calendarId = event.calendarID
        platformId = event.platformId
        icalUid = key.icalUid
        recurrenceId = key.recurrenceId
        createdAt = now
        updatedAt = now
    }

    static func upsert(event: CalendarEvent, key: CalendarEventKey, now: Date, in db: Database) throws {
        var record = Self(now: now, event: event, key: key)
        if let existing = try filter(Column("platform") == record.platform)
            .filter(Column("calendar_id") == record.calendarId)
            .filter(Column("platform_id") == record.platformId)
            .fetchOne(db) {
            record.createdAt = existing.createdAt
        }
        try record.save(db)
    }
}
