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
    var attendees: [CalendarAttendeeSnapshot] = []

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
        case attendees = "attendees_json"
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
        attendees = event.participants.attendeeSnapshots
    }

    static func upsert(event: CalendarEvent, now: Date, in db: Database) throws {
        guard let key = event.key else { return }

        var record = Self(now: now, event: event, key: key)
        let existing = try fetch(key: key, in: db)
        if let existing {
            record.createdAt = existing.createdAt
            record.title = record.title.nilIfBlank ?? existing.title
            record.description = record.description.nilIfBlank ?? existing.description
            record.conferenceURI = record.conferenceURI ?? existing.conferenceURI
            record.url = record.url ?? existing.url
        }
        try record.save(db)
        try CalendarEventSourceRecord.upsert(event: event, key: key, now: now, in: db)
        try MeetingCalendarSync.recordChange(from: existing, to: record, in: db)
    }

    static func refreshLinked(events: [CalendarEvent], now: Date, in db: Database) throws {
        let linkedKeys = try Set(Row.fetchAll(db, sql: """
        SELECT DISTINCT calendar_event_ical_uid AS icalUid,
                        calendar_event_recurrence_id AS recurrenceId
        FROM meetings
        WHERE calendar_event_ical_uid IS NOT NULL
          AND calendar_event_recurrence_id IS NOT NULL
        """).compactMap { row -> CalendarEventKey? in
            guard let icalUid: String = row["icalUid"],
                  let recurrenceId: String = row["recurrenceId"] else { return nil }
            return CalendarEventKey(icalUid: icalUid, recurrenceId: recurrenceId)
        })
        var eventByKey: [CalendarEventKey: CalendarEvent] = [:]
        for event in events {
            guard let key = event.key, linkedKeys.contains(key) else { continue }
            guard let existing = eventByKey[key] else {
                eventByKey[key] = event
                continue
            }
            let eventIsGoogle = event.platform == CalendarEventPlatform.googleCalendar
            let existingIsGoogle = existing.platform == CalendarEventPlatform.googleCalendar
            let eventAttendees = event.participants.attendeeSnapshots
            let existingAttendees = existing.participants.attendeeSnapshots
            if (eventIsGoogle && !existingIsGoogle)
                || (eventIsGoogle == existingIsGoogle && eventAttendees.count > existingAttendees.count)
                || (eventIsGoogle == existingIsGoogle && eventAttendees.count == existingAttendees.count
                    && event.id < existing.id) {
                eventByKey[key] = event
            }
        }
        for event in eventByKey.values {
            try upsert(event: event, now: now, in: db)
        }
    }

    static func fetch(key: CalendarEventKey, in db: Database) throws -> Self? {
        try filter(Column("ical_uid") == key.icalUid)
            .filter(Column("recurrence_id") == key.recurrenceId)
            .fetchOne(db)
    }
}
