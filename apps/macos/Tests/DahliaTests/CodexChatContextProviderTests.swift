import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct CodexChatContextProviderTests {
        @Test
        func savedMeetingUsesLatestDatabaseSnapshotAndActiveVault() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let vault = testVault(name: "Active")
            let otherVault = testVault(name: "Other")
            let event = testCalendarEvent(icalUID: "planning@example.com")
            let key = try #require(event.key)
            let meetingID = UUID.v7()
            let now = Date(timeIntervalSince1970: 1_704_067_200)

            try await database.dbQueue.write { db in
                try vault.insert(db)
                try otherVault.insert(db)
                try CalendarEventRecord.upsert(event: event, now: now, in: db)
                try MeetingRecord(
                    id: meetingID,
                    vaultId: vault.id,
                    projectId: nil,
                    name: "Initial name",
                    status: .ready,
                    duration: nil,
                    createdAt: now,
                    updatedAt: now,
                    calendarEventIcalUid: key.icalUid,
                    calendarEventRecurrenceId: key.recurrenceId
                ).insert(db)
            }

            let provider = CodexChatContextProvider()
            provider.update(
                vaultID: vault.id,
                meetingID: meetingID,
                draftMeeting: nil,
                dbQueue: database.dbQueue
            )

            let initial = try await provider.currentContext(vaultID: vault.id)
            guard case let .meeting(id, name, calendarEvent) = initial else {
                Issue.record("Expected saved Meeting context")
                return
            }
            #expect(id == meetingID)
            #expect(name == "Initial name")
            #expect(calendarEvent?.icalUID == "planning@example.com")

            try await database.dbQueue.write { db in
                guard var meeting = try MeetingRecord.fetchOne(db, key: meetingID) else {
                    throw CodexAppServerError.invalidProtocolResponse
                }
                meeting.name = "Latest name"
                meeting.updatedAt = now.addingTimeInterval(60)
                try meeting.update(db)
            }

            guard case let .meeting(_, latestName, _) = try await provider.currentContext(vaultID: vault.id) else {
                Issue.record("Expected updated Meeting context")
                return
            }
            #expect(latestName == "Latest name")
            #expect(try await provider.currentContext(vaultID: otherVault.id) == nil)
        }

        @Test
        func draftIsReturnedWithoutCreatingDatabaseMeeting() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let vault = testVault(name: "Draft")
            try await database.dbQueue.write { db in
                try vault.insert(db)
            }
            let event = testCalendarEvent(icalUID: nil)
            let draft = DraftMeeting(
                id: UUID.v7(),
                title: "Unsaved planning",
                linkedCalendarEvent: event
            )
            let provider = CodexChatContextProvider()
            provider.update(
                vaultID: vault.id,
                meetingID: nil,
                draftMeeting: draft,
                dbQueue: database.dbQueue
            )

            let context = try await provider.currentContext(vaultID: vault.id)
            let meetingCount = try await database.dbQueue.read { db in
                try MeetingRecord.fetchCount(db)
            }

            guard case let .meetingDraft(id, name, calendarEvent) = context else {
                Issue.record("Expected MeetingDraft context")
                return
            }
            #expect(id == draft.id)
            #expect(name == "Unsaved planning")
            #expect(calendarEvent?.icalUID == nil)
            #expect(meetingCount == 0)
            #expect(try await provider.currentContext(vaultID: UUID.v7()) == nil)
        }

        @Test
        func selectedMeetingResolutionFailuresThrow() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let activeVault = testVault(name: "Active")
            let otherVault = testVault(name: "Other")
            let otherMeetingID = UUID.v7()
            try await database.dbQueue.write { db in
                try activeVault.insert(db)
                try otherVault.insert(db)
                try MeetingRecord(
                    id: otherMeetingID,
                    vaultId: otherVault.id,
                    projectId: nil,
                    name: "Other vault meeting",
                    status: .ready,
                    duration: nil,
                    createdAt: .now,
                    updatedAt: .now
                ).insert(db)
            }
            let provider = CodexChatContextProvider()

            provider.update(
                vaultID: activeVault.id,
                meetingID: UUID.v7(),
                draftMeeting: nil,
                dbQueue: nil
            )
            await #expect(throws: CodexChatContextError.selectedMeetingUnavailable) {
                try await provider.currentContext(vaultID: activeVault.id)
            }

            provider.update(
                vaultID: activeVault.id,
                meetingID: UUID.v7(),
                draftMeeting: nil,
                dbQueue: database.dbQueue
            )
            await #expect(throws: CodexChatContextError.selectedMeetingUnavailable) {
                try await provider.currentContext(vaultID: activeVault.id)
            }

            provider.update(
                vaultID: activeVault.id,
                meetingID: otherMeetingID,
                draftMeeting: nil,
                dbQueue: database.dbQueue
            )
            await #expect(throws: CodexChatContextError.selectedMeetingUnavailable) {
                try await provider.currentContext(vaultID: activeVault.id)
            }
        }

        private func testVault(name: String) -> VaultRecord {
            VaultRecord(
                id: .v7(),
                path: "/tmp/codex-chat-context-\(name)",
                name: name,
                createdAt: .now,
                lastOpenedAt: .now
            )
        }

        private func testCalendarEvent(icalUID: String?) -> CalendarEvent {
            let start = Date(timeIntervalSince1970: 1_704_067_200)
            return CalendarEvent(
                id: "event",
                calendarID: "calendar",
                calendarName: "Work",
                calendarColorHex: nil,
                platformId: "event-platform-id",
                title: "Planning",
                description: "Agenda",
                icalUid: icalUID,
                startDate: start,
                endDate: start.addingTimeInterval(3600),
                isAllDay: false,
                conferenceURI: nil
            )
        }
    }
#endif
