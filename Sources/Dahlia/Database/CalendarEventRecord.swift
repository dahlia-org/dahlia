import Foundation
import GRDB

struct CalendarEventRecord: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "calendar_events"
    static let googleCalendarPlatform = CalendarEventPlatform.googleCalendar
    static let macOSCalendarPlatform = CalendarEventPlatform.macOSCalendar

    var id: Int64? = nil
    var meetingId: UUID
    var createdAt: Date
    var updatedAt: Date
    var platform: String
    var platformId: String
    var description: String
    var icalUid: String?
    var start: Date
    var end: Date
    var meetingUrl: String?

    init(
        id: Int64? = nil,
        meetingId: UUID,
        createdAt: Date,
        updatedAt: Date,
        platform: String,
        platformId: String,
        description: String,
        icalUid: String?,
        start: Date,
        end: Date,
        meetingUrl: String?
    ) {
        self.id = id
        self.meetingId = meetingId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.platform = platform
        self.platformId = platformId
        self.description = description
        self.icalUid = icalUid
        self.start = start
        self.end = end
        self.meetingUrl = meetingUrl
    }

    init(meetingId: UUID, now: Date, event: CalendarEvent) {
        self.init(
            meetingId: meetingId,
            createdAt: now,
            updatedAt: now,
            platform: event.platform,
            platformId: event.platformId,
            description: event.description,
            icalUid: event.icalUid,
            start: event.startDate,
            end: event.endDate,
            meetingUrl: event.meetingURL?.absoluteString
        )
    }
}
