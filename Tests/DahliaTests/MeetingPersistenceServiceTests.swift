import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    // swiftlint:disable:next type_body_length
    struct MeetingPersistenceServiceTests {
        @Test
        func newMeetingStartsPersistedAsReady() throws {
            let database = try makeDatabase()
            let store = TranscriptStore()
            let startDate = Date(timeIntervalSince1970: 1_776_384_000)
            store.recordingStartTime = startDate

            let service = try MeetingPersistenceService(
                store: store,
                dbQueue: database.dbQueue,
                vaultId: testVault.id,
                projectId: nil,
                initialName: "Runtime status meeting"
            )

            let persisted = try database.dbQueue.read { db in
                let meeting = try MeetingRecord.fetchOne(db, key: service.meetingId)
                return try #require(meeting)
            }

            #expect(persisted.status == .ready)
        }

        @Test
        func batchMeetingDoesNotPersistRealtimeSegments() async throws {
            let database = try makeDatabase()
            let store = TranscriptStore()
            let startDate = Date(timeIntervalSince1970: 1_776_384_000)
            store.recordingStartTime = startDate

            let service = try MeetingPersistenceService(
                store: store,
                dbQueue: database.dbQueue,
                vaultId: testVault.id,
                projectId: nil,
                initialName: "Batch meeting",
                transcriptionMode: .batch,
                persistencePolicy: .deferred,
                retainAudioAfterBatch: true
            )
            store.addSegment(
                TranscriptSegment(
                    startTime: startDate,
                    text: "Must not be persisted",
                    isConfirmed: true,
                    speakerLabel: "mic"
                )
            )
            await service.stop()

            let result = try await database.dbQueue.read { db in
                let meeting = try MeetingRecord.fetchOne(db, key: service.meetingId)
                let session = try RecordingSessionRecord.fetchOne(db, key: service.recordingSessionId)
                let segmentCount = try TranscriptSegmentRecord
                    .filter(Column("meetingId") == service.meetingId)
                    .fetchCount(db)
                return try (#require(meeting), #require(session), segmentCount)
            }

            #expect(result.0.status == .transcriptNotFound)
            #expect(result.1.transcriptionMode == .batch)
            #expect(result.1.retainAudioAfterBatch)
            #expect(result.2 == 0)
        }

        @Test
        func batchStopPreservesFailureMetadataWrittenDuringFinalization() async throws {
            let database = try makeDatabase()
            let store = TranscriptStore()
            store.recordingStartTime = Date(timeIntervalSince1970: 1_776_384_000)
            let service = try MeetingPersistenceService(
                store: store,
                dbQueue: database.dbQueue,
                vaultId: testVault.id,
                projectId: nil,
                initialName: "Failed batch meeting",
                transcriptionMode: .batch,
                persistencePolicy: .deferred
            )
            let attemptDate = Date(timeIntervalSince1970: 1_776_384_030)
            try await database.dbQueue.write { db in
                try db.execute(
                    sql: """
                    UPDATE recording_sessions
                    SET batchLastError = ?, batchLastAttemptAt = ?, batchAttemptCount = ?
                    WHERE id = ?
                    """,
                    arguments: ["CAF write failed", attemptDate, 2, service.recordingSessionId]
                )
            }

            await service.stop()

            let session = try await database.dbQueue.read { db in
                let record = try RecordingSessionRecord.fetchOne(db, key: service.recordingSessionId)
                return try #require(record)
            }
            #expect(session.endedAt != nil)
            #expect(session.duration != nil)
            #expect(session.batchLastError == "CAF write failed")
            #expect(session.batchLastAttemptAt == attemptDate)
            #expect(session.batchAttemptCount == 2)
        }

        @Test
        func appendModeDoesNotChangePersistedStatusOnStart() async throws {
            let database = try makeDatabase()
            let meetingId = UUID.v7()
            let createdAt = Date(timeIntervalSince1970: 1_776_384_000)

            try await database.dbQueue.write { db in
                try MeetingRecord(
                    id: meetingId,
                    vaultId: testVault.id,
                    projectId: nil,
                    name: "Existing meeting",
                    status: .transcriptNotFound,
                    duration: nil,
                    createdAt: createdAt,
                    updatedAt: createdAt
                ).insert(db)
            }

            _ = try MeetingPersistenceService(
                store: TranscriptStore(),
                dbQueue: database.dbQueue,
                existingMeetingId: meetingId,
                existingSegmentIds: []
            )

            let persisted = try await database.dbQueue.read { db in
                let meeting = try MeetingRecord.fetchOne(db, key: meetingId)
                return try #require(meeting)
            }

            #expect(persisted.status == .transcriptNotFound)
            #expect(persisted.updatedAt == createdAt)
        }

        @Test
        func appendModeDurationUsesSessionStartDate() async throws {
            let database = try makeDatabase()
            let meetingId = UUID.v7()
            let createdAt = Date(timeIntervalSince1970: 1_776_384_000)
            let sessionStartDate = Date()
            let store = TranscriptStore()
            store.recordingStartTime = createdAt

            try await database.dbQueue.write { db in
                try MeetingRecord(
                    id: meetingId,
                    vaultId: testVault.id,
                    projectId: nil,
                    name: "Existing meeting",
                    status: .ready,
                    duration: nil,
                    createdAt: createdAt,
                    updatedAt: createdAt
                ).insert(db)
            }

            let service = try MeetingPersistenceService(
                store: store,
                dbQueue: database.dbQueue,
                existingMeetingId: meetingId,
                existingSegmentIds: [],
                recordingStartDate: sessionStartDate
            )
            await service.stop()

            let persisted = try await database.dbQueue.read { db in
                let meeting = try MeetingRecord.fetchOne(db, key: meetingId)
                return try #require(meeting)
            }

            #expect((persisted.duration ?? .greatestFiniteMagnitude) < 10)
        }

        @Test
        func appendModePersistsSegmentsWithNewRecordingSessionOffset() async throws {
            let database = try makeDatabase()
            let meetingId = UUID.v7()
            let firstSessionId = UUID.v7()
            let secondSessionStart = Date()
            let firstSessionStart = secondSessionStart.addingTimeInterval(-300)
            let store = TranscriptStore()
            store.recordingStartTime = firstSessionStart

            try await database.dbQueue.write { db in
                try MeetingRecord(
                    id: meetingId,
                    vaultId: testVault.id,
                    projectId: nil,
                    name: "Existing meeting",
                    status: .ready,
                    duration: 10,
                    createdAt: firstSessionStart,
                    updatedAt: firstSessionStart.addingTimeInterval(10)
                ).insert(db)
                try RecordingSessionRecord(
                    id: firstSessionId,
                    meetingId: meetingId,
                    startedAt: firstSessionStart,
                    endedAt: firstSessionStart.addingTimeInterval(10),
                    duration: 10,
                    offsetSeconds: 0,
                    createdAt: firstSessionStart,
                    updatedAt: firstSessionStart.addingTimeInterval(10)
                ).insert(db)
            }

            let service = try MeetingPersistenceService(
                store: store,
                dbQueue: database.dbQueue,
                existingMeetingId: meetingId,
                existingSegmentIds: [],
                recordingStartDate: secondSessionStart,
                recordingOffsetSeconds: 10
            )
            let segment = TranscriptSegment(
                startTime: secondSessionStart.addingTimeInterval(3),
                text: "After pause",
                isConfirmed: true,
                speakerLabel: "mic"
            )

            store.loadSegments([segment])
            await service.stop()

            let persisted = try await waitForAppendPersistence(
                database: database,
                meetingId: meetingId,
                segmentId: segment.id
            )
            let segmentRecord = try #require(persisted.segment)
            let meetingRecord = try #require(persisted.meeting)

            let secondSession = try #require(persisted.sessions.first(where: { $0.id == service.recordingSessionId }))
            #expect(secondSession.offsetSeconds == 10)
            #expect(segmentRecord.sessionId == secondSession.id)
            #expect((meetingRecord.duration ?? 0) >= 10)
            #expect((meetingRecord.duration ?? 0) < 20)
        }

        @Test
        func cancellingAppendRemovesOnlyCurrentSessionSegments() async throws {
            let database = try makeDatabase()
            let meetingId = UUID.v7()
            let createdAt = Date(timeIntervalSince1970: 1_776_384_000)
            let legacySegment = TranscriptSegment(
                startTime: createdAt,
                text: "Existing transcript",
                isConfirmed: true,
                speakerLabel: "mic"
            )
            try await database.dbQueue.write { db in
                try MeetingRecord(
                    id: meetingId,
                    vaultId: testVault.id,
                    projectId: nil,
                    name: "Existing meeting",
                    status: .ready,
                    createdAt: createdAt,
                    updatedAt: createdAt
                ).insert(db)
                try TranscriptSegmentRecord(from: legacySegment, meetingId: meetingId).insert(db)
            }
            let service = try MeetingPersistenceService(
                store: TranscriptStore(),
                dbQueue: database.dbQueue,
                existingMeetingId: meetingId,
                existingSegmentIds: [legacySegment.id],
                recordingStartDate: createdAt.addingTimeInterval(60)
            )
            let appendedSegment = TranscriptSegment(
                sessionId: service.recordingSessionId,
                startTime: createdAt.addingTimeInterval(60),
                text: "Cancelled append",
                isConfirmed: true,
                speakerLabel: "mic"
            )
            try await service.persist(.finalized(appendedSegment))

            await service.cancel()

            let persisted = try await database.dbQueue.read { db in
                (
                    try TranscriptSegmentRecord.fetchOne(db, key: legacySegment.id),
                    try TranscriptSegmentRecord.fetchOne(db, key: appendedSegment.id),
                    try RecordingSessionRecord.fetchOne(db, key: service.recordingSessionId)
                )
            }
            #expect(persisted.0?.text == legacySegment.text)
            #expect(persisted.1 == nil)
            #expect(persisted.2 == nil)
        }

        @Test
        func newMeetingPersistsLinkedCalendarEvent() async throws {
            let database = try makeDatabase()
            let store = TranscriptStore()
            let startDate = Date(timeIntervalSince1970: 1_776_384_000)
            store.recordingStartTime = startDate

            let service = try MeetingPersistenceService(
                store: store,
                dbQueue: database.dbQueue,
                vaultId: testVault.id,
                projectId: nil,
                initialName: "Design review",
                calendarEvent: fixtureEvent(startDate: startDate)
            )
            await service.stop()

            let persisted = try await database.dbQueue.read { db in
                let meeting = try MeetingRecord.fetchOne(db, key: service.meetingId)
                let calendarEvent = try linkedCalendarEvent(meetingId: service.meetingId, in: db)
                let source = try CalendarEventSourceRecord
                    .filter(Column("platform") == CalendarEventPlatform.googleCalendar)
                    .filter(Column("platform_id") == "event-1")
                    .fetchOne(db)
                return try (
                    #require(meeting),
                    #require(calendarEvent),
                    #require(source)
                )
            }

            #expect(persisted.0.name == "Design review")
            #expect(persisted.0.calendarEventIcalUid == "event-1@google.com")
            #expect(persisted.0.calendarEventRecurrenceId?.isEmpty == true)
            #expect(persisted.1.description == "Review launch checklist")
            #expect(persisted.1.icalUid == "event-1@google.com")
            #expect(persisted.1.start == startDate)
            #expect(persisted.1.end == startDate.addingTimeInterval(3600))
            #expect(persisted.1.conferenceURI == "https://meet.google.com/test-link")
            #expect(persisted.1.url == "https://calendar.google.com/calendar/event?eid=event-1")
            #expect(persisted.2.platformId == "event-1")
        }

        @Test
        func newMeetingPersistsLinkedMacCalendarEventPlatform() async throws {
            let database = try makeDatabase()
            let store = TranscriptStore()
            let startDate = Date(timeIntervalSince1970: 1_776_384_000)
            store.recordingStartTime = startDate

            let service = try MeetingPersistenceService(
                store: store,
                dbQueue: database.dbQueue,
                vaultId: testVault.id,
                projectId: nil,
                initialName: "Mac event review",
                calendarEvent: fixtureMacCalendarEvent(startDate: startDate)
            )
            await service.stop()

            let persisted = try await database.dbQueue.read { db in
                let calendarEvent = try linkedCalendarEvent(meetingId: service.meetingId, in: db)
                let source = try CalendarEventSourceRecord
                    .filter(Column("platform") == CalendarEventPlatform.macOSCalendar)
                    .filter(Column("platform_id") == "mac-event-1::1776384000")
                    .fetchOne(db)
                return try (#require(calendarEvent), #require(source))
            }

            #expect(persisted.0.description == "Local calendar notes")
            #expect(persisted.0.icalUid == "mac-event-1@local")
            #expect(persisted.1.platform == CalendarEventPlatform.macOSCalendar)
            #expect(persisted.1.platformId == "mac-event-1::1776384000")
        }

        @Test
        func eventWithoutUIDCreatesMeetingWithoutSyntheticCalendarLink() async throws {
            let database = try makeDatabase()
            let startDate = Date(timeIntervalSince1970: 1_776_384_000)
            let event = CalendarEvent(
                id: "local::missing-uid",
                calendarID: "local",
                calendarName: "Local",
                calendarColorHex: nil,
                platform: CalendarEventPlatform.macOSCalendar,
                platformId: "missing-uid",
                title: "Local event",
                description: "",
                icalUid: nil,
                startDate: startDate,
                endDate: startDate.addingTimeInterval(3600),
                isAllDay: false,
                conferenceURI: nil
            )

            let service = try MeetingPersistenceService(
                store: TranscriptStore(),
                dbQueue: database.dbQueue,
                vaultId: testVault.id,
                projectId: nil,
                initialName: event.title,
                calendarEvent: event
            )
            await service.stop()

            let result = try await database.dbQueue.read { db in
                let meeting = try MeetingRecord.fetchOne(db, key: service.meetingId)
                return try (
                    #require(meeting),
                    CalendarEventRecord.fetchCount(db)
                )
            }

            #expect(result.0.calendarEventIcalUid == nil)
            #expect(result.0.calendarEventRecurrenceId == nil)
            #expect(result.1 == 0)
        }

        @Test
        func appendModeDoesNotCreateAdditionalCalendarEvent() async throws {
            let database = try makeDatabase()
            let meetingId = UUID.v7()
            let createdAt = Date(timeIntervalSince1970: 1_776_384_000)
            let event = fixtureEvent(startDate: createdAt)
            let key = try #require(event.key)

            try await database.dbQueue.write { db in
                try CalendarEventRecord.upsert(event: event, now: createdAt, in: db)
                try MeetingRecord(
                    id: meetingId,
                    vaultId: testVault.id,
                    projectId: nil,
                    name: "Existing meeting",
                    status: .ready,
                    duration: 120,
                    createdAt: createdAt,
                    updatedAt: createdAt,
                    calendarEventIcalUid: key.icalUid,
                    calendarEventRecurrenceId: key.recurrenceId
                ).insert(db)
            }

            let service = try MeetingPersistenceService(
                store: TranscriptStore(),
                dbQueue: database.dbQueue,
                existingMeetingId: meetingId,
                existingSegmentIds: []
            )
            await service.stop()

            let calendarEventCount = try await database.dbQueue.read { db in
                try CalendarEventRecord.fetchCount(db)
            }

            #expect(calendarEventCount == 1)
        }

        @Test
        func sameCalendarEventCanLinkMultipleMeetingsAndSurvivesMeetingDeletion() throws {
            let database = try makeDatabase()
            let firstMeetingId = UUID.v7()
            let secondMeetingId = UUID.v7()
            let createdAt = Date(timeIntervalSince1970: 1_776_384_000)
            let event = fixtureEvent(startDate: createdAt)
            let key = try #require(event.key)

            try database.dbQueue.write { db in
                try CalendarEventRecord.upsert(event: event, now: createdAt, in: db)
                try MeetingRecord(
                    id: firstMeetingId,
                    vaultId: testVault.id,
                    projectId: nil,
                    name: "First",
                    status: .ready,
                    duration: nil,
                    createdAt: createdAt,
                    updatedAt: createdAt,
                    calendarEventIcalUid: key.icalUid,
                    calendarEventRecurrenceId: key.recurrenceId
                ).insert(db)
                try MeetingRecord(
                    id: secondMeetingId,
                    vaultId: testVault.id,
                    projectId: nil,
                    name: "Second",
                    status: .ready,
                    duration: nil,
                    createdAt: createdAt.addingTimeInterval(1),
                    updatedAt: createdAt.addingTimeInterval(1),
                    calendarEventIcalUid: key.icalUid,
                    calendarEventRecurrenceId: key.recurrenceId
                ).insert(db)
            }

            let linkedMeetingCount = try database.dbQueue.read { db in
                try MeetingRecord
                    .filter(Column("calendar_event_ical_uid") == key.icalUid)
                    .filter(Column("calendar_event_recurrence_id") == key.recurrenceId)
                    .fetchCount(db)
            }
            #expect(linkedMeetingCount == 2)

            let repository = MeetingRepository(dbQueue: database.dbQueue)
            #expect(try repository.resolveMeetingIdForCalendarEvent(event, vaultId: testVault.id) == secondMeetingId)

            #expect(throws: Error.self) {
                try database.dbQueue.write { db in
                    _ = try CalendarEventRecord
                        .filter(Column("ical_uid") == key.icalUid)
                        .filter(Column("recurrence_id") == key.recurrenceId)
                        .deleteAll(db)
                }
            }

            try repository.deleteMeeting(id: firstMeetingId)

            let calendarEventCount = try database.dbQueue.read { db in
                try CalendarEventRecord.fetchCount(db)
            }

            #expect(calendarEventCount == 1)
        }

        @Test
        func resolveMeetingIdForCalendarEventReturnsPersistedMeeting() throws {
            let database = try makeDatabase()
            let meetingId = UUID.v7()
            let createdAt = Date(timeIntervalSince1970: 1_776_384_000)
            let event = fixtureEvent(startDate: createdAt)
            let key = try #require(event.key)

            try database.dbQueue.write { db in
                try CalendarEventRecord.upsert(event: event, now: createdAt, in: db)
                try MeetingRecord(
                    id: meetingId,
                    vaultId: testVault.id,
                    projectId: nil,
                    name: "Existing meeting",
                    status: .ready,
                    duration: nil,
                    createdAt: createdAt,
                    updatedAt: createdAt,
                    calendarEventIcalUid: key.icalUid,
                    calendarEventRecurrenceId: key.recurrenceId
                ).insert(db)
            }

            let repository = MeetingRepository(dbQueue: database.dbQueue)
            let resolvedMeetingId = try repository.resolveMeetingIdForCalendarEvent(event, vaultId: testVault.id)

            #expect(resolvedMeetingId == meetingId)
        }

        @Test
        func stopPersistsTranslatedTextWhenAvailableBeforeInsert() async throws {
            let database = try makeDatabase()
            let store = TranscriptStore()
            let startDate = Date(timeIntervalSince1970: 1_776_384_000)
            store.recordingStartTime = startDate

            let service = try MeetingPersistenceService(
                store: store,
                dbQueue: database.dbQueue,
                vaultId: testVault.id,
                projectId: nil,
                initialName: "Translated meeting"
            )
            let segment = TranscriptSegment(
                startTime: startDate,
                text: "Hello world",
                translatedText: "こんにちは、世界",
                isConfirmed: true,
                speakerLabel: "mic"
            )

            store.loadSegments([segment])
            await service.stop()

            let persisted = try await database.dbQueue.read { db in
                let segmentRecord = try TranscriptSegmentRecord.fetchOne(db, key: segment.id)
                return try #require(segmentRecord)
            }

            #expect(persisted.text == "Hello world")
            #expect(persisted.translatedText == "こんにちは、世界")
        }

        @Test
        func finalizedEventsPersistWithoutWaitingForStoreProjection() async throws {
            let database = try makeDatabase()
            let store = TranscriptStore()
            let startDate = Date(timeIntervalSince1970: 1_776_384_000)
            store.recordingStartTime = startDate
            let service = try MeetingPersistenceService(
                store: store,
                dbQueue: database.dbQueue,
                vaultId: testVault.id,
                projectId: nil,
                initialName: "Independent persistence"
            )
            let segment = TranscriptSegment(
                sessionId: service.recordingSessionId,
                startTime: startDate,
                text: "Persist without UI",
                isConfirmed: true,
                speakerLabel: "mic"
            )

            try await service.persist(.finalized(segment))
            try await service.persist(
                .translation(
                    sessionId: service.recordingSessionId,
                    segmentID: segment.id,
                    translatedText: "UI を待たずに保存"
                )
            )

            let persisted = try await database.dbQueue.read { db in
                let record = try TranscriptSegmentRecord.fetchOne(db, key: segment.id)
                return try #require(record)
            }
            #expect(store.segments.isEmpty)
            #expect(persisted.text == segment.text)
            #expect(persisted.translatedText == "UI を待たずに保存")

            await service.stop()
        }

        @Test
        func translatedTextUpdatesExistingPersistedSegment() async throws {
            let database = try makeDatabase()
            let store = TranscriptStore()
            let startDate = Date(timeIntervalSince1970: 1_776_384_000)
            store.recordingStartTime = startDate

            let service = try MeetingPersistenceService(
                store: store,
                dbQueue: database.dbQueue,
                vaultId: testVault.id,
                projectId: nil,
                initialName: "Translated meeting"
            )
            let segment = TranscriptSegment(
                startTime: startDate,
                text: "Hello world",
                isConfirmed: true,
                speakerLabel: "mic"
            )

            try await service.persist(.finalized(segment))
            store.loadSegments([segment])
            store.updateTranslatedText(for: segment.id, translatedText: "こんにちは、世界")
            try await service.persist(
                .translation(
                    sessionId: service.recordingSessionId,
                    segmentID: segment.id,
                    translatedText: "こんにちは、世界"
                )
            )
            await service.stop()

            let persisted = try await database.dbQueue.read { db in
                let segmentRecord = try TranscriptSegmentRecord.fetchOne(db, key: segment.id)
                return try #require(segmentRecord)
            }

            #expect(persisted.translatedText == "こんにちは、世界")
        }

        @Test
        func unconfirmedTranslatedTextIsNotPersisted() async throws {
            let database = try makeDatabase()
            let store = TranscriptStore()
            let startDate = Date(timeIntervalSince1970: 1_776_384_000)
            store.recordingStartTime = startDate

            let service = try MeetingPersistenceService(
                store: store,
                dbQueue: database.dbQueue,
                vaultId: testVault.id,
                projectId: nil,
                initialName: "Preview meeting"
            )

            store.updateUnconfirmedSegment(
                TranscriptSegment(
                    startTime: startDate,
                    text: "Preview",
                    translatedText: "プレビュー",
                    isConfirmed: false,
                    speakerLabel: "mic"
                ),
                forSource: "mic"
            )
            await service.stop()

            let persistedCount = try await database.dbQueue.read { db in
                try TranscriptSegmentRecord.fetchCount(db)
            }

            #expect(persistedCount == 0)
        }
    }

#elseif canImport(XCTest)
    import XCTest

    @MainActor
    final class MeetingPersistenceServiceTests: XCTestCase {
        func testNewMeetingPersistsLinkedCalendarEvent() async throws {
            let database = try makeDatabase()
            let store = TranscriptStore()
            let startDate = Date(timeIntervalSince1970: 1_776_384_000)
            store.recordingStartTime = startDate

            let service = try MeetingPersistenceService(
                store: store,
                dbQueue: database.dbQueue,
                vaultId: testVault.id,
                projectId: nil,
                initialName: "Design review",
                calendarEvent: fixtureEvent(startDate: startDate)
            )
            await service.stop()

            let persisted = try await database.dbQueue.read { db in
                try (
                    XCTUnwrap(MeetingRecord.fetchOne(db, key: service.meetingId)),
                    XCTUnwrap(linkedCalendarEvent(meetingId: service.meetingId, in: db)),
                    XCTUnwrap(
                        CalendarEventSourceRecord
                            .filter(Column("platform") == CalendarEventPlatform.googleCalendar)
                            .filter(Column("platform_id") == "event-1")
                            .fetchOne(db)
                    )
                )
            }

            XCTAssertEqual(persisted.0.name, "Design review")
            XCTAssertEqual(persisted.0.calendarEventIcalUid, "event-1@google.com")
            XCTAssertEqual(persisted.1.description, "Review launch checklist")
            XCTAssertEqual(persisted.1.icalUid, "event-1@google.com")
            XCTAssertEqual(persisted.1.start, startDate)
            XCTAssertEqual(persisted.1.end, startDate.addingTimeInterval(3600))
            XCTAssertEqual(persisted.1.conferenceURI, "https://meet.google.com/test-link")
            XCTAssertEqual(persisted.2.platformId, "event-1")
        }

        func testAppendModeDoesNotCreateAdditionalCalendarEvent() async throws {
            let database = try makeDatabase()
            let meetingId = UUID.v7()
            let createdAt = Date(timeIntervalSince1970: 1_776_384_000)
            let event = fixtureEvent(startDate: createdAt)
            let key = try XCTUnwrap(event.key)

            try await database.dbQueue.write { db in
                try CalendarEventRecord.upsert(event: event, now: createdAt, in: db)
                try MeetingRecord(
                    id: meetingId,
                    vaultId: testVault.id,
                    projectId: nil,
                    name: "Existing meeting",
                    status: .ready,
                    duration: 120,
                    createdAt: createdAt,
                    updatedAt: createdAt,
                    calendarEventIcalUid: key.icalUid,
                    calendarEventRecurrenceId: key.recurrenceId
                ).insert(db)
            }

            let service = try MeetingPersistenceService(
                store: TranscriptStore(),
                dbQueue: database.dbQueue,
                existingMeetingId: meetingId,
                existingSegmentIds: []
            )
            await service.stop()

            let calendarEventCount = try await database.dbQueue.read { db in
                try CalendarEventRecord.fetchCount(db)
            }

            XCTAssertEqual(calendarEventCount, 1)
        }

        func testSameCalendarEventCanLinkMultipleMeetingsAndSurvivesMeetingDeletion() throws {
            let database = try makeDatabase()
            let firstMeetingId = UUID.v7()
            let secondMeetingId = UUID.v7()
            let createdAt = Date(timeIntervalSince1970: 1_776_384_000)
            let event = fixtureEvent(startDate: createdAt)
            let key = try XCTUnwrap(event.key)

            try database.dbQueue.write { db in
                try CalendarEventRecord.upsert(event: event, now: createdAt, in: db)
                try MeetingRecord(
                    id: firstMeetingId,
                    vaultId: testVault.id,
                    projectId: nil,
                    name: "First",
                    status: .ready,
                    duration: nil,
                    createdAt: createdAt,
                    updatedAt: createdAt,
                    calendarEventIcalUid: key.icalUid,
                    calendarEventRecurrenceId: key.recurrenceId
                ).insert(db)
                try MeetingRecord(
                    id: secondMeetingId,
                    vaultId: testVault.id,
                    projectId: nil,
                    name: "Second",
                    status: .ready,
                    duration: nil,
                    createdAt: createdAt.addingTimeInterval(1),
                    updatedAt: createdAt.addingTimeInterval(1),
                    calendarEventIcalUid: key.icalUid,
                    calendarEventRecurrenceId: key.recurrenceId
                ).insert(db)
            }

            let repository = MeetingRepository(dbQueue: database.dbQueue)
            XCTAssertEqual(
                try repository.resolveMeetingIdForCalendarEvent(event, vaultId: testVault.id),
                secondMeetingId
            )
            try repository.deleteMeeting(id: firstMeetingId)

            let calendarEventCount = try database.dbQueue.read { db in
                try CalendarEventRecord.fetchCount(db)
            }

            XCTAssertEqual(calendarEventCount, 1)
        }

        func testFetchMeetingIdForCalendarEventReturnsPersistedMeeting() throws {
            let database = try makeDatabase()
            let meetingId = UUID.v7()
            let createdAt = Date(timeIntervalSince1970: 1_776_384_000)
            let event = fixtureEvent(startDate: createdAt)
            let key = try XCTUnwrap(event.key)

            try database.dbQueue.write { db in
                try CalendarEventRecord.upsert(event: event, now: createdAt, in: db)
                try MeetingRecord(
                    id: meetingId,
                    vaultId: testVault.id,
                    projectId: nil,
                    name: "Existing meeting",
                    status: .ready,
                    duration: nil,
                    createdAt: createdAt,
                    updatedAt: createdAt,
                    calendarEventIcalUid: key.icalUid,
                    calendarEventRecurrenceId: key.recurrenceId
                ).insert(db)
            }

            let repository = MeetingRepository(dbQueue: database.dbQueue)
            let resolvedMeetingId = try repository.resolveMeetingIdForCalendarEvent(event, vaultId: testVault.id)

            XCTAssertEqual(resolvedMeetingId, meetingId)
        }

        func testStopPersistsTranslatedTextWhenAvailableBeforeInsert() async throws {
            let database = try makeDatabase()
            let store = TranscriptStore()
            let startDate = Date(timeIntervalSince1970: 1_776_384_000)
            store.recordingStartTime = startDate

            let service = try MeetingPersistenceService(
                store: store,
                dbQueue: database.dbQueue,
                vaultId: testVault.id,
                projectId: nil,
                initialName: "Translated meeting"
            )
            let segment = TranscriptSegment(
                startTime: startDate,
                text: "Hello world",
                translatedText: "こんにちは、世界",
                isConfirmed: true,
                speakerLabel: "mic"
            )

            store.loadSegments([segment])
            await service.stop()

            let persisted = try await database.dbQueue.read { db in
                try XCTUnwrap(TranscriptSegmentRecord.fetchOne(db, key: segment.id))
            }

            XCTAssertEqual(persisted.text, "Hello world")
            XCTAssertEqual(persisted.translatedText, "こんにちは、世界")
        }

        func testTranslatedTextUpdatesExistingPersistedSegment() async throws {
            let database = try makeDatabase()
            let store = TranscriptStore()
            let startDate = Date(timeIntervalSince1970: 1_776_384_000)
            store.recordingStartTime = startDate

            let service = try MeetingPersistenceService(
                store: store,
                dbQueue: database.dbQueue,
                vaultId: testVault.id,
                projectId: nil,
                initialName: "Translated meeting"
            )
            let segment = TranscriptSegment(
                startTime: startDate,
                text: "Hello world",
                isConfirmed: true,
                speakerLabel: "mic"
            )

            try await service.persist(.finalized(segment))
            store.loadSegments([segment])
            store.updateTranslatedText(for: segment.id, translatedText: "こんにちは、世界")
            try await service.persist(
                .translation(
                    sessionId: service.recordingSessionId,
                    segmentID: segment.id,
                    translatedText: "こんにちは、世界"
                )
            )
            await service.stop()

            let persisted = try await database.dbQueue.read { db in
                try XCTUnwrap(TranscriptSegmentRecord.fetchOne(db, key: segment.id))
            }

            XCTAssertEqual(persisted.translatedText, "こんにちは、世界")
        }

        func testUnconfirmedTranslatedTextIsNotPersisted() async throws {
            let database = try makeDatabase()
            let store = TranscriptStore()
            let startDate = Date(timeIntervalSince1970: 1_776_384_000)
            store.recordingStartTime = startDate

            let service = try MeetingPersistenceService(
                store: store,
                dbQueue: database.dbQueue,
                vaultId: testVault.id,
                projectId: nil,
                initialName: "Preview meeting"
            )

            store.updateUnconfirmedSegment(
                TranscriptSegment(
                    startTime: startDate,
                    text: "Preview",
                    translatedText: "プレビュー",
                    isConfirmed: false,
                    speakerLabel: "mic"
                ),
                forSource: "mic"
            )
            await service.stop()

            let persistedCount = try await database.dbQueue.read { db in
                try TranscriptSegmentRecord.fetchCount(db)
            }

            XCTAssertEqual(persistedCount, 0)
        }
    }
#endif

private let testVault = VaultRecord(
    id: .v7(),
    path: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).path,
    name: "Test Vault",
    createdAt: Date(timeIntervalSince1970: 1_776_380_000),
    lastOpenedAt: Date(timeIntervalSince1970: 1_776_380_000)
)

private func makeDatabase() throws -> AppDatabaseManager {
    let database = try AppDatabaseManager(path: ":memory:")
    try database.dbQueue.write { db in
        try testVault.insert(db)
    }
    return database
}

private struct PersistedAppendState {
    let sessions: [RecordingSessionRecord]
    let segment: TranscriptSegmentRecord?
    let meeting: MeetingRecord?
}

private func waitForAppendPersistence(
    database: AppDatabaseManager,
    meetingId: UUID,
    segmentId: UUID,
    timeout: Duration = .seconds(5)
) async throws -> PersistedAppendState {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout

    while clock.now < deadline {
        let state = try fetchAppendPersistence(database: database, meetingId: meetingId, segmentId: segmentId)
        if state.segment != nil, state.meeting != nil {
            return state
        }
        try? await Task.sleep(for: .milliseconds(20))
    }

    return try fetchAppendPersistence(database: database, meetingId: meetingId, segmentId: segmentId)
}

private func fetchAppendPersistence(
    database: AppDatabaseManager,
    meetingId: UUID,
    segmentId: UUID
) throws -> PersistedAppendState {
    try database.dbQueue.read { db in
        let sessions = try RecordingSessionRecord
            .filter(Column("meetingId") == meetingId)
            .order(Column("offsetSeconds").asc)
            .fetchAll(db)
        let segment = try TranscriptSegmentRecord.fetchOne(db, key: segmentId)
        let meeting = try MeetingRecord.fetchOne(db, key: meetingId)
        return PersistedAppendState(sessions: sessions, segment: segment, meeting: meeting)
    }
}

private func linkedCalendarEvent(meetingId: UUID, in db: Database) throws -> CalendarEventRecord? {
    guard let meeting = try MeetingRecord.fetchOne(db, key: meetingId),
          let icalUid = meeting.calendarEventIcalUid,
          let recurrenceId = meeting.calendarEventRecurrenceId
    else { return nil }

    return try CalendarEventRecord.fetch(
        key: CalendarEventKey(icalUid: icalUid, recurrenceId: recurrenceId),
        in: db
    )
}

private func fixtureEvent(startDate: Date) -> GoogleCalendarEvent {
    GoogleCalendarEvent(
        id: "primary::event-1",
        calendarID: "primary",
        calendarName: "Primary",
        calendarColorHex: "#4285F4",
        platformId: "event-1",
        title: "Design review",
        description: "Review launch checklist",
        icalUid: "event-1@google.com",
        startDate: startDate,
        endDate: startDate.addingTimeInterval(3600),
        isAllDay: false,
        conferenceURI: URL(string: "https://meet.google.com/test-link"),
        url: URL(string: "https://calendar.google.com/calendar/event?eid=event-1")
    )
}

private func fixtureMacCalendarEvent(startDate: Date) -> CalendarEvent {
    CalendarEvent(
        id: "local::mac-event-1",
        calendarID: "local",
        calendarName: "Local",
        calendarColorHex: "#FF9500",
        platform: CalendarEventPlatform.macOSCalendar,
        platformId: "mac-event-1::1776384000",
        title: "Mac event review",
        description: "Local calendar notes",
        icalUid: "mac-event-1@local",
        startDate: startDate,
        endDate: startDate.addingTimeInterval(3600),
        isAllDay: false,
        conferenceURI: URL(string: "https://zoom.us/j/123456789")
    )
}
