import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct CodexChatContextProviderTests {
        @Test
        func projectUsesLatestDatabaseSnapshotAndActiveWorkspace() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let workspace = testWorkspace(name: "Active Project")
            let otherWorkspace = testWorkspace(name: "Other Project")
            let projectID = UUID.v7()
            try await database.dbQueue.write { db in
                try workspace.insert(db)
                try otherWorkspace.insert(db)
                try ProjectRecord(
                    id: projectID,
                    workspaceId: workspace.id,
                    parentProjectId: nil,
                    name: "Project",
                    createdAt: .now,
                    description: "Initial",
                    projectType: .customer
                ).insert(db)
            }
            let provider = CodexChatContextProvider()
            provider.update(
                workspaceID: workspace.id,
                meetingID: nil,
                projectID: projectID,
                draftMeeting: nil,
                dbQueue: database.dbQueue
            )

            #expect(try await provider.currentContext(workspaceID: workspace.id) == .project(
                id: projectID,
                name: "Project",
                description: "Initial"
            ))

            try await database.dbQueue.write { db in
                let fetchedProject = try ProjectRecord.fetchOne(db, key: projectID)
                var project = try #require(fetchedProject)
                project.description = "Latest"
                try project.update(db)
            }

            #expect(try await provider.currentContext(workspaceID: workspace.id) == .project(
                id: projectID,
                name: "Project",
                description: "Latest"
            ))
            #expect(try await provider.currentContext(workspaceID: otherWorkspace.id) == nil)
        }

        @Test
        func savedMeetingUsesLatestDatabaseSnapshotAndActiveWorkspace() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let workspace = testWorkspace(name: "Active")
            let otherWorkspace = testWorkspace(name: "Other")
            let event = testCalendarEvent(icalUID: "planning@example.com")
            let key = try #require(event.key)
            let meetingID = UUID.v7()
            let now = Date(timeIntervalSince1970: 1_704_067_200)

            try await database.dbQueue.write { db in
                try workspace.insert(db)
                try otherWorkspace.insert(db)
                try CalendarEventRecord.upsert(event: event, now: now, in: db)
                try MeetingRecord(
                    id: meetingID,
                    workspaceId: workspace.id,
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
                workspaceID: workspace.id,
                meetingID: meetingID,
                draftMeeting: nil,
                dbQueue: database.dbQueue
            )

            let initial = try await provider.currentContext(workspaceID: workspace.id)
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

            guard case let .meeting(_, latestName, _) = try await provider.currentContext(workspaceID: workspace.id) else {
                Issue.record("Expected updated Meeting context")
                return
            }
            #expect(latestName == "Latest name")
            #expect(try await provider.currentContext(workspaceID: otherWorkspace.id) == nil)
        }

        @Test
        func draftIsReturnedWithoutCreatingDatabaseMeeting() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let workspace = testWorkspace(name: "Draft")
            try await database.dbQueue.write { db in
                try workspace.insert(db)
            }
            let event = testCalendarEvent(icalUID: nil)
            let draft = DraftMeeting(
                id: UUID.v7(),
                title: "Unsaved planning",
                linkedCalendarEvent: event
            )
            let provider = CodexChatContextProvider()
            provider.update(
                workspaceID: workspace.id,
                meetingID: nil,
                draftMeeting: draft,
                dbQueue: database.dbQueue
            )

            let context = try await provider.currentContext(workspaceID: workspace.id)
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
            #expect(try await provider.currentContext(workspaceID: UUID.v7()) == nil)
        }

        @Test
        func selectedMeetingResolutionFailuresThrow() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let activeWorkspace = testWorkspace(name: "Active")
            let otherWorkspace = testWorkspace(name: "Other")
            let otherMeetingID = UUID.v7()
            try await database.dbQueue.write { db in
                try activeWorkspace.insert(db)
                try otherWorkspace.insert(db)
                try MeetingRecord(
                    id: otherMeetingID,
                    workspaceId: otherWorkspace.id,
                    projectId: nil,
                    name: "Other workspace meeting",
                    status: .ready,
                    duration: nil,
                    createdAt: .now,
                    updatedAt: .now
                ).insert(db)
            }
            let provider = CodexChatContextProvider()

            provider.update(
                workspaceID: activeWorkspace.id,
                meetingID: UUID.v7(),
                draftMeeting: nil,
                dbQueue: nil
            )
            await #expect(throws: CodexChatContextError.selectedMeetingUnavailable) {
                try await provider.currentContext(workspaceID: activeWorkspace.id)
            }

            provider.update(
                workspaceID: activeWorkspace.id,
                meetingID: UUID.v7(),
                draftMeeting: nil,
                dbQueue: database.dbQueue
            )
            await #expect(throws: CodexChatContextError.selectedMeetingUnavailable) {
                try await provider.currentContext(workspaceID: activeWorkspace.id)
            }

            provider.update(
                workspaceID: activeWorkspace.id,
                meetingID: otherMeetingID,
                draftMeeting: nil,
                dbQueue: database.dbQueue
            )
            await #expect(throws: CodexChatContextError.selectedMeetingUnavailable) {
                try await provider.currentContext(workspaceID: activeWorkspace.id)
            }
        }

        private func testWorkspace(name: String) -> WorkspaceRecord {
            WorkspaceRecord(
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
