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
        func batchMeetingDoesNotPersistRealtimeSegments() throws {
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
            service.stop()

            let result = try database.dbQueue.read { db in
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
        func batchStopPreservesFailureMetadataWrittenDuringFinalization() throws {
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
            try database.dbQueue.write { db in
                try db.execute(
                    sql: """
                    UPDATE recording_sessions
                    SET batchLastError = ?, batchLastAttemptAt = ?, batchAttemptCount = ?
                    WHERE id = ?
                    """,
                    arguments: ["CAF write failed", attemptDate, 2, service.recordingSessionId]
                )
            }

            service.stop()

            let session = try database.dbQueue.read { db in
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
        func appendModeDoesNotChangePersistedStatusOnStart() throws {
            let database = try makeDatabase()
            let meetingId = UUID.v7()
            let createdAt = Date(timeIntervalSince1970: 1_776_384_000)

            try database.dbQueue.write { db in
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

            let persisted = try database.dbQueue.read { db in
                let meeting = try MeetingRecord.fetchOne(db, key: meetingId)
                return try #require(meeting)
            }

            #expect(persisted.status == .transcriptNotFound)
            #expect(persisted.updatedAt == createdAt)
        }

        @Test
        func appendModeDurationUsesSessionStartDate() throws {
            let database = try makeDatabase()
            let meetingId = UUID.v7()
            let createdAt = Date(timeIntervalSince1970: 1_776_384_000)
            let sessionStartDate = Date()
            let store = TranscriptStore()
            store.recordingStartTime = createdAt

            try database.dbQueue.write { db in
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
            service.stop()

            let persisted = try database.dbQueue.read { db in
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
            service.stop()

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
        func newMeetingPersistsLinkedCalendarEvent() throws {
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
            service.stop()

            let persisted = try database.dbQueue.read { db in
                let meeting = try MeetingRecord.fetchOne(db, key: service.meetingId)
                let calendarEvent = try CalendarEventRecord.filter(Column("meetingId") == service.meetingId).fetchOne(db)
                return try (
                    #require(meeting),
                    #require(calendarEvent)
                )
            }

            #expect(persisted.0.name == "Design review")
            #expect(persisted.1.platform == "GoogleCalendar")
            #expect(persisted.1.platformId == "event-1")
            #expect(persisted.1.description == "Review launch checklist")
            #expect(persisted.1.icalUid == "event-1@google.com")
            #expect(persisted.1.start == startDate)
            #expect(persisted.1.end == startDate.addingTimeInterval(3600))
            #expect(persisted.1.meetingUrl == "https://meet.google.com/test-link")
        }

        @Test
        func newMeetingPersistsLinkedMacCalendarEventPlatform() throws {
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
            service.stop()

            let persisted = try database.dbQueue.read { db in
                let calendarEvent = try CalendarEventRecord.filter(Column("meetingId") == service.meetingId).fetchOne(db)
                return try #require(calendarEvent)
            }

            #expect(persisted.platform == "MacOSCalendar")
            #expect(persisted.platformId == "mac-event-1::1776384000")
            #expect(persisted.description == "Local calendar notes")
            #expect(persisted.icalUid == "mac-event-1@local")
        }

        @Test
        func appendModeDoesNotCreateAdditionalCalendarEvent() throws {
            let database = try makeDatabase()
            let meetingId = UUID.v7()
            let createdAt = Date(timeIntervalSince1970: 1_776_384_000)

            try database.dbQueue.write { db in
                try MeetingRecord(
                    id: meetingId,
                    vaultId: testVault.id,
                    projectId: nil,
                    name: "Existing meeting",
                    status: .ready,
                    duration: 120,
                    createdAt: createdAt,
                    updatedAt: createdAt
                ).insert(db)
                try CalendarEventRecord(
                    meetingId: meetingId,
                    createdAt: createdAt,
                    updatedAt: createdAt,
                    platform: "GoogleCalendar",
                    platformId: "event-1",
                    description: "Review launch checklist",
                    icalUid: "event-1@google.com",
                    start: createdAt,
                    end: createdAt.addingTimeInterval(3600),
                    meetingUrl: "https://meet.google.com/test-link"
                ).insert(db)
            }

            let service = try MeetingPersistenceService(
                store: TranscriptStore(),
                dbQueue: database.dbQueue,
                existingMeetingId: meetingId,
                existingSegmentIds: []
            )
            service.stop()

            let calendarEventCount = try database.dbQueue.read { db in
                try CalendarEventRecord.fetchCount(db)
            }

            #expect(calendarEventCount == 1)
        }

        @Test
        func calendarEventConstraintsEnforceUniquenessAndCascadeDelete() throws {
            let database = try makeDatabase()
            let firstMeetingId = UUID.v7()
            let secondMeetingId = UUID.v7()
            let createdAt = Date(timeIntervalSince1970: 1_776_384_000)

            try database.dbQueue.write { db in
                try MeetingRecord(
                    id: firstMeetingId,
                    vaultId: testVault.id,
                    projectId: nil,
                    name: "First",
                    status: .ready,
                    duration: nil,
                    createdAt: createdAt,
                    updatedAt: createdAt
                ).insert(db)
                try MeetingRecord(
                    id: secondMeetingId,
                    vaultId: testVault.id,
                    projectId: nil,
                    name: "Second",
                    status: .ready,
                    duration: nil,
                    createdAt: createdAt,
                    updatedAt: createdAt
                ).insert(db)
                try CalendarEventRecord(
                    meetingId: firstMeetingId,
                    createdAt: createdAt,
                    updatedAt: createdAt,
                    platform: "GoogleCalendar",
                    platformId: "event-1",
                    description: "",
                    icalUid: nil,
                    start: createdAt,
                    end: createdAt.addingTimeInterval(3600),
                    meetingUrl: nil
                ).insert(db)
            }

            #expect(throws: Error.self) {
                try database.dbQueue.write { db in
                    try CalendarEventRecord(
                        meetingId: secondMeetingId,
                        createdAt: createdAt,
                        updatedAt: createdAt,
                        platform: "GoogleCalendar",
                        platformId: "event-1",
                        description: "",
                        icalUid: nil,
                        start: createdAt,
                        end: createdAt.addingTimeInterval(3600),
                        meetingUrl: nil
                    ).insert(db)
                }
            }

            let repository = MeetingRepository(dbQueue: database.dbQueue)
            try repository.deleteMeeting(id: firstMeetingId)

            let calendarEventCount = try database.dbQueue.read { db in
                try CalendarEventRecord.fetchCount(db)
            }

            #expect(calendarEventCount == 0)
        }

        @Test
        func fetchMeetingIdForCalendarEventReturnsPersistedMeeting() throws {
            let database = try makeDatabase()
            let meetingId = UUID.v7()
            let createdAt = Date(timeIntervalSince1970: 1_776_384_000)

            try database.dbQueue.write { db in
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
                try CalendarEventRecord(
                    meetingId: meetingId,
                    createdAt: createdAt,
                    updatedAt: createdAt,
                    platform: "GoogleCalendar",
                    platformId: "event-1",
                    description: "",
                    icalUid: nil,
                    start: createdAt,
                    end: createdAt.addingTimeInterval(3600),
                    meetingUrl: nil
                ).insert(db)
            }

            let repository = MeetingRepository(dbQueue: database.dbQueue)
            let resolvedMeetingId = try repository.fetchMeetingIdForCalendarEvent(
                platform: "GoogleCalendar",
                platformId: "event-1"
            )

            #expect(resolvedMeetingId == meetingId)
        }

        @Test
        func stopPersistsTranslatedTextWhenAvailableBeforeInsert() throws {
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
            service.stop()

            let persisted = try database.dbQueue.read { db in
                let segmentRecord = try TranscriptSegmentRecord.fetchOne(db, key: segment.id)
                return try #require(segmentRecord)
            }

            #expect(persisted.text == "Hello world")
            #expect(persisted.translatedText == "こんにちは、世界")
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

            store.loadSegments([segment])
            try await Task.sleep(for: .milliseconds(700))

            store.updateTranslatedText(for: segment.id, translatedText: "こんにちは、世界")
            try await Task.sleep(for: .milliseconds(700))
            service.stop()

            let persisted = try await database.dbQueue.read { db in
                let segmentRecord = try TranscriptSegmentRecord.fetchOne(db, key: segment.id)
                return try #require(segmentRecord)
            }

            #expect(persisted.translatedText == "こんにちは、世界")
        }

        @Test
        func unconfirmedTranslatedTextIsNotPersisted() throws {
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
            service.stop()

            let persistedCount = try database.dbQueue.read { db in
                try TranscriptSegmentRecord.fetchCount(db)
            }

            #expect(persistedCount == 0)
        }
    }

#elseif canImport(XCTest)
    import XCTest

    @MainActor
    final class MeetingPersistenceServiceTests: XCTestCase {
        func testNewMeetingPersistsLinkedCalendarEvent() throws {
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
            service.stop()

            let persisted = try database.dbQueue.read { db in
                try (
                    XCTUnwrap(MeetingRecord.fetchOne(db, key: service.meetingId)),
                    XCTUnwrap(CalendarEventRecord.filter(Column("meetingId") == service.meetingId).fetchOne(db))
                )
            }

            XCTAssertEqual(persisted.0.name, "Design review")
            XCTAssertEqual(persisted.1.platform, "GoogleCalendar")
            XCTAssertEqual(persisted.1.platformId, "event-1")
            XCTAssertEqual(persisted.1.description, "Review launch checklist")
            XCTAssertEqual(persisted.1.icalUid, "event-1@google.com")
            XCTAssertEqual(persisted.1.start, startDate)
            XCTAssertEqual(persisted.1.end, startDate.addingTimeInterval(3600))
            XCTAssertEqual(persisted.1.meetingUrl, "https://meet.google.com/test-link")
        }

        func testAppendModeDoesNotCreateAdditionalCalendarEvent() throws {
            let database = try makeDatabase()
            let meetingId = UUID.v7()
            let createdAt = Date(timeIntervalSince1970: 1_776_384_000)

            try database.dbQueue.write { db in
                try MeetingRecord(
                    id: meetingId,
                    vaultId: testVault.id,
                    projectId: nil,
                    name: "Existing meeting",
                    status: .ready,
                    duration: 120,
                    createdAt: createdAt,
                    updatedAt: createdAt
                ).insert(db)
                try CalendarEventRecord(
                    meetingId: meetingId,
                    createdAt: createdAt,
                    updatedAt: createdAt,
                    platform: "GoogleCalendar",
                    platformId: "event-1",
                    description: "Review launch checklist",
                    icalUid: "event-1@google.com",
                    start: createdAt,
                    end: createdAt.addingTimeInterval(3600),
                    meetingUrl: "https://meet.google.com/test-link"
                ).insert(db)
            }

            let service = try MeetingPersistenceService(
                store: TranscriptStore(),
                dbQueue: database.dbQueue,
                existingMeetingId: meetingId,
                existingSegmentIds: []
            )
            service.stop()

            let calendarEventCount = try database.dbQueue.read { db in
                try CalendarEventRecord.fetchCount(db)
            }

            XCTAssertEqual(calendarEventCount, 1)
        }

        func testCalendarEventConstraintsEnforceUniquenessAndCascadeDelete() throws {
            let database = try makeDatabase()
            let firstMeetingId = UUID.v7()
            let secondMeetingId = UUID.v7()
            let createdAt = Date(timeIntervalSince1970: 1_776_384_000)

            try database.dbQueue.write { db in
                try MeetingRecord(
                    id: firstMeetingId,
                    vaultId: testVault.id,
                    projectId: nil,
                    name: "First",
                    status: .ready,
                    duration: nil,
                    createdAt: createdAt,
                    updatedAt: createdAt
                ).insert(db)
                try MeetingRecord(
                    id: secondMeetingId,
                    vaultId: testVault.id,
                    projectId: nil,
                    name: "Second",
                    status: .ready,
                    duration: nil,
                    createdAt: createdAt,
                    updatedAt: createdAt
                ).insert(db)
                try CalendarEventRecord(
                    meetingId: firstMeetingId,
                    createdAt: createdAt,
                    updatedAt: createdAt,
                    platform: "GoogleCalendar",
                    platformId: "event-1",
                    description: "",
                    icalUid: nil,
                    start: createdAt,
                    end: createdAt.addingTimeInterval(3600),
                    meetingUrl: nil
                ).insert(db)
            }

            XCTAssertThrowsError(
                try database.dbQueue.write { db in
                    try CalendarEventRecord(
                        meetingId: secondMeetingId,
                        createdAt: createdAt,
                        updatedAt: createdAt,
                        platform: "GoogleCalendar",
                        platformId: "event-1",
                        description: "",
                        icalUid: nil,
                        start: createdAt,
                        end: createdAt.addingTimeInterval(3600),
                        meetingUrl: nil
                    ).insert(db)
                }
            )

            let repository = MeetingRepository(dbQueue: database.dbQueue)
            try repository.deleteMeeting(id: firstMeetingId)

            let calendarEventCount = try database.dbQueue.read { db in
                try CalendarEventRecord.fetchCount(db)
            }

            XCTAssertEqual(calendarEventCount, 0)
        }

        func testFetchMeetingIdForCalendarEventReturnsPersistedMeeting() throws {
            let database = try makeDatabase()
            let meetingId = UUID.v7()
            let createdAt = Date(timeIntervalSince1970: 1_776_384_000)

            try database.dbQueue.write { db in
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
                try CalendarEventRecord(
                    meetingId: meetingId,
                    createdAt: createdAt,
                    updatedAt: createdAt,
                    platform: "GoogleCalendar",
                    platformId: "event-1",
                    description: "",
                    icalUid: nil,
                    start: createdAt,
                    end: createdAt.addingTimeInterval(3600),
                    meetingUrl: nil
                ).insert(db)
            }

            let repository = MeetingRepository(dbQueue: database.dbQueue)
            let resolvedMeetingId = try repository.fetchMeetingIdForCalendarEvent(
                platform: "GoogleCalendar",
                platformId: "event-1"
            )

            XCTAssertEqual(resolvedMeetingId, meetingId)
        }

        func testStopPersistsTranslatedTextWhenAvailableBeforeInsert() throws {
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
            service.stop()

            let persisted = try database.dbQueue.read { db in
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

            store.loadSegments([segment])
            try await Task.sleep(for: .milliseconds(700))

            store.updateTranslatedText(for: segment.id, translatedText: "こんにちは、世界")
            try await Task.sleep(for: .milliseconds(700))
            service.stop()

            let persisted = try database.dbQueue.read { db in
                try XCTUnwrap(TranscriptSegmentRecord.fetchOne(db, key: segment.id))
            }

            XCTAssertEqual(persisted.translatedText, "こんにちは、世界")
        }

        func testUnconfirmedTranslatedTextIsNotPersisted() throws {
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
            service.stop()

            let persistedCount = try database.dbQueue.read { db in
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
        meetingURL: URL(string: "https://meet.google.com/test-link")
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
        meetingURL: URL(string: "https://zoom.us/j/123456789")
    )
}
