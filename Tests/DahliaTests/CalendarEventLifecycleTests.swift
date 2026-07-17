import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct CalendarEventLifecycleTests {
        @Test
        func upsertFromSparseSourcePreservesRicherCanonicalMetadata() throws {
            let (database, _) = try makeDatabase(named: "Canonical Merge")
            let conferenceURI = try #require(URL(string: "https://meet.google.com/planning"))
            let eventURL = try #require(URL(string: "https://calendar.google.com/calendar/event?eid=planning"))
            let richEvent = event(
                url: eventURL,
                description: "Quarterly planning",
                conferenceURI: conferenceURI
            )
            let sparseEvent = event(
                platform: CalendarEventPlatform.macOSCalendar,
                calendarID: "mac-calendar",
                platformId: "mac-event"
            )
            let key = try #require(richEvent.key)

            let persisted = try database.dbQueue.write { db in
                try CalendarEventRecord.upsert(event: richEvent, now: .now, in: db)
                try CalendarEventRecord.upsert(event: sparseEvent, now: .now, in: db)
                return try CalendarEventRecord.fetch(key: key, in: db)
            }

            #expect(persisted?.description == richEvent.description)
            #expect(persisted?.conferenceURI == conferenceURI.absoluteString)
            #expect(persisted?.url == eventURL.absoluteString)
        }

        @Test
        func resolvingExistingMeetingRefreshesCanonicalEventAndSourceMapping() throws {
            let (database, vault) = try makeDatabase(named: "Source Refresh")
            let createdAt = Date(timeIntervalSince1970: 1_776_384_000)
            let meetingId = UUID.v7()
            let macEvent = event(
                platform: CalendarEventPlatform.macOSCalendar,
                calendarID: "mac-calendar",
                platformId: "mac-event"
            )
            let googleURL = try #require(URL(string: "https://calendar.google.com/calendar/event?eid=planning"))
            let googleEvent = event(url: googleURL, platformId: "google-event")
            let key = try #require(macEvent.key)

            try database.dbQueue.write { db in
                try CalendarEventRecord.upsert(event: macEvent, now: createdAt, in: db)
                try insertMeeting(id: meetingId, vaultId: vault.id, createdAt: createdAt, key: key, in: db)
            }

            let repository = MeetingRepository(dbQueue: database.dbQueue)
            let resolvedMeetingId = try repository.resolveMeetingIdForCalendarEvent(
                googleEvent,
                vaultId: vault.id,
                observedAt: createdAt.addingTimeInterval(60)
            )
            let persisted = try database.dbQueue.read { db in
                try (
                    CalendarEventRecord.fetch(key: key, in: db),
                    CalendarEventSourceRecord.fetchCount(db)
                )
            }

            #expect(resolvedMeetingId == meetingId)
            #expect(persisted.0?.url == googleURL.absoluteString)
            #expect(persisted.1 == 2)
        }

        @Test
        func calendarEventIsDeletedAfterItsLastMeetingReference() throws {
            let (database, vault) = try makeDatabase(named: "Reference Cleanup")
            let calendarEvent = event()
            let key = try #require(calendarEvent.key)
            let firstMeetingId = UUID.v7()
            let secondMeetingId = UUID.v7()

            try database.dbQueue.write { db in
                try CalendarEventRecord.upsert(event: calendarEvent, now: .now, in: db)
                try insertMeeting(id: firstMeetingId, vaultId: vault.id, createdAt: .now, key: key, in: db)
                try insertMeeting(id: secondMeetingId, vaultId: vault.id, createdAt: .now, key: key, in: db)
                _ = try MeetingRecord.deleteOne(db, key: firstMeetingId)
            }

            let afterFirstDeletion = try calendarRecordCounts(in: database)
            #expect(afterFirstDeletion.events == 1)
            #expect(afterFirstDeletion.sources == 1)

            try database.dbQueue.write { db in
                _ = try MeetingRecord.deleteOne(db, key: secondMeetingId)
            }
            let afterLastDeletion = try calendarRecordCounts(in: database)
            #expect(afterLastDeletion.events == 0)
            #expect(afterLastDeletion.sources == 0)
        }

        @Test
        func cancellingNewMeetingDeletesUnreferencedCalendarEvent() async throws {
            let (database, vault) = try makeDatabase(named: "Cancellation Cleanup")
            let calendarEvent = event()
            let service = try MeetingPersistenceService(
                store: TranscriptStore(),
                dbQueue: database.dbQueue,
                vaultId: vault.id,
                projectId: nil,
                initialName: calendarEvent.title,
                calendarEvent: calendarEvent
            )

            await service.cancel()

            let meetingCount = try await database.dbQueue.read { db in
                try MeetingRecord.fetchCount(db)
            }
            let calendarCounts = try calendarRecordCounts(in: database)
            #expect(meetingCount == 0)
            #expect(calendarCounts.events == 0)
            #expect(calendarCounts.sources == 0)
        }

        private func makeDatabase(named name: String) throws -> (AppDatabaseManager, VaultRecord) {
            let database = try AppDatabaseManager(path: ":memory:")
            let vault = VaultRecord(
                id: .v7(),
                path: "/tmp/calendar-lifecycle-\(UUID().uuidString)",
                name: name,
                createdAt: .now,
                lastOpenedAt: .now
            )
            try database.dbQueue.write { db in
                try vault.insert(db)
            }
            return (database, vault)
        }

        private func event(
            url: URL? = nil,
            platform: String = CalendarEventPlatform.googleCalendar,
            calendarID: String = "primary",
            platformId: String = "planning",
            description: String = "",
            conferenceURI: URL? = nil
        ) -> CalendarEvent {
            let start = Date(timeIntervalSince1970: 1_776_384_000)
            return CalendarEvent(
                id: "\(platform)::\(platformId)",
                calendarID: calendarID,
                calendarName: "Primary",
                calendarColorHex: nil,
                platform: platform,
                platformId: platformId,
                title: "Planning",
                description: description,
                icalUid: "planning@example.com",
                startDate: start,
                endDate: start.addingTimeInterval(3600),
                isAllDay: false,
                conferenceURI: conferenceURI,
                url: url
            )
        }

        private func insertMeeting(
            id: UUID,
            vaultId: UUID,
            createdAt: Date,
            key: CalendarEventKey,
            in db: Database
        ) throws {
            try MeetingRecord(
                id: id,
                vaultId: vaultId,
                projectId: nil,
                name: "Planning",
                createdAt: createdAt,
                updatedAt: createdAt,
                calendarEventIcalUid: key.icalUid,
                calendarEventRecurrenceId: key.recurrenceId
            ).insert(db)
        }

        private func calendarRecordCounts(
            in database: AppDatabaseManager
        ) throws -> (events: Int, sources: Int) {
            try database.dbQueue.read { db in
                try (CalendarEventRecord.fetchCount(db), CalendarEventSourceRecord.fetchCount(db))
            }
        }
    }
#endif
