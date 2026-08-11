import Foundation
import GRDB

struct CalendarEventRecord: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "calendar_events"

    var icalUid: String
    var recurrenceId: String
    var createdAt: Date
    var updatedAt: Date
    var title: String
    var description: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var conferenceURI: String?
    var url: String?

    enum CodingKeys: String, CodingKey {
        case icalUid = "ical_uid"
        case recurrenceId = "recurrence_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case title
        case description
        case start
        case end
        case isAllDay = "is_all_day"
        case conferenceURI = "conference_uri"
        case url
    }

    init(now: Date, event: CalendarEvent, key: CalendarEventKey) {
        icalUid = key.icalUid
        recurrenceId = key.recurrenceId
        createdAt = now
        updatedAt = now
        title = event.title
        description = event.description
        start = event.startDate
        end = event.endDate
        isAllDay = event.isAllDay
        conferenceURI = event.conferenceURI?.absoluteString.nilIfBlank
        url = event.url?.absoluteString.nilIfBlank
    }

    static func upsert(event: CalendarEvent, now: Date, in db: Database) throws {
        guard let key = event.key else { return }

        var record = Self(now: now, event: event, key: key)
        if let existing = try fetch(key: key, in: db) {
            record.createdAt = existing.createdAt
            record.title = record.title.nilIfBlank ?? existing.title
            record.description = record.description.nilIfBlank ?? existing.description
            record.conferenceURI = record.conferenceURI ?? existing.conferenceURI
            record.url = record.url ?? existing.url
        }
        try record.save(db)
        try CalendarEventSourceRecord.upsert(event: event, key: key, now: now, in: db)
    }

    static func fetch(key: CalendarEventKey, in db: Database) throws -> Self? {
        try filter(Column("ical_uid") == key.icalUid)
            .filter(Column("recurrence_id") == key.recurrenceId)
            .fetchOne(db)
    }
}
