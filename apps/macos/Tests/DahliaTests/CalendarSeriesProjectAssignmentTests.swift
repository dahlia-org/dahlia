import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct CalendarSeriesProjectAssignmentTests {
        @Test
        func newMeetingInheritsProjectFromMostRecentEarlierOccurrence() async throws {
            let (database, workspace) = try makeDatabase()
            let olderProject = project(named: "Older project", workspaceId: workspace.id)
            let recentProject = project(named: "Recent project", workspaceId: workspace.id)
            let futureProject = project(named: "Future project", workspaceId: workspace.id)
            let olderStart = Date(timeIntervalSince1970: 1_776_200_000)
            let recentStart = Date(timeIntervalSince1970: 1_776_300_000)
            let currentStart = Date(timeIntervalSince1970: 1_776_400_000)
            let futureStart = Date(timeIntervalSince1970: 1_776_500_000)

            try await database.dbQueue.write { db in
                try olderProject.insert(db)
                try recentProject.insert(db)
                try futureProject.insert(db)
                try insertSeriesMeeting(
                    event: seriesEvent(startDate: olderStart, recurrenceId: "20260414T090000Z"),
                    projectId: olderProject.id,
                    workspaceId: workspace.id,
                    createdAt: recentStart.addingTimeInterval(100),
                    in: db
                )
                try insertSeriesMeeting(
                    event: seriesEvent(startDate: recentStart, recurrenceId: "20260415T090000Z"),
                    projectId: recentProject.id,
                    workspaceId: workspace.id,
                    createdAt: olderStart,
                    in: db
                )
                try insertSeriesMeeting(
                    event: seriesEvent(startDate: futureStart, recurrenceId: "20260417T090000Z"),
                    projectId: futureProject.id,
                    workspaceId: workspace.id,
                    createdAt: futureStart,
                    in: db
                )
            }

            let service = try await MeetingPersistenceService.createNew(
                store: TranscriptStore(),
                dbQueue: database.dbQueue,
                workspaceId: workspace.id,
                projectId: nil,
                initialName: "Current occurrence",
                calendarEvent: seriesEvent(startDate: currentStart, recurrenceId: "20260416T090000Z")
            )
            await service.stop()

            let meeting = try fetchMeeting(id: service.meetingId, from: database.dbQueue)
            #expect(meeting.projectId == recentProject.id)
            #expect(service.projectId == recentProject.id)
        }

        @Test
        func inheritedSubprojectUsesResolvedLogicalPath() async throws {
            let (database, workspace) = try makeDatabase()
            let root = project(named: "Acme", workspaceId: workspace.id)
            let child = ProjectRecord(
                id: .v7(),
                workspaceId: workspace.id,
                parentProjectId: root.id,
                name: "Platform",
                createdAt: .now,
                projectType: nil
            )
            let previousStart = Date(timeIntervalSince1970: 1_776_300_000)
            let currentStart = Date(timeIntervalSince1970: 1_776_400_000)

            try await database.dbQueue.write { db in
                try root.insert(db)
                try child.insert(db)
                try insertSeriesMeeting(
                    event: seriesEvent(startDate: previousStart, recurrenceId: "20260415T090000Z"),
                    projectId: child.id,
                    workspaceId: workspace.id,
                    createdAt: previousStart,
                    in: db
                )
            }

            let service = try await MeetingPersistenceService.createNew(
                store: TranscriptStore(),
                dbQueue: database.dbQueue,
                workspaceId: workspace.id,
                projectId: nil,
                initialName: "Current occurrence",
                calendarEvent: seriesEvent(startDate: currentStart, recurrenceId: "20260416T090000Z")
            )
            await service.stop()

            #expect(service.projectId == child.id)
            #expect(service.projectName == "Acme/Platform")
        }

        @Test
        func explicitlySelectedProjectOverridesSeriesProject() async throws {
            let (database, workspace) = try makeDatabase()
            let seriesProject = project(named: "Series project", workspaceId: workspace.id)
            let selectedProject = project(named: "Selected project", workspaceId: workspace.id)
            let previousStart = Date(timeIntervalSince1970: 1_776_300_000)
            let currentStart = Date(timeIntervalSince1970: 1_776_400_000)

            try await database.dbQueue.write { db in
                try seriesProject.insert(db)
                try selectedProject.insert(db)
                try insertSeriesMeeting(
                    event: seriesEvent(startDate: previousStart, recurrenceId: "20260415T090000Z"),
                    projectId: seriesProject.id,
                    workspaceId: workspace.id,
                    createdAt: previousStart,
                    in: db
                )
            }

            let service = try await MeetingPersistenceService.createNew(
                store: TranscriptStore(),
                dbQueue: database.dbQueue,
                workspaceId: workspace.id,
                projectId: selectedProject.id,
                initialName: "Current occurrence",
                calendarEvent: seriesEvent(startDate: currentStart, recurrenceId: "20260416T090000Z")
            )
            await service.stop()

            let meeting = try fetchMeeting(id: service.meetingId, from: database.dbQueue)
            #expect(meeting.projectId == selectedProject.id)
            #expect(service.projectId == selectedProject.id)
        }

        @Test
        func explicitNoProjectPreventsSeriesInheritanceWhenRecordingStarts() async throws {
            let (database, workspace) = try makeDatabase()
            let inheritedProject = project(named: "Planning", workspaceId: workspace.id)
            let previousStart = Date(timeIntervalSince1970: 1_776_300_000)
            let currentStart = Date(timeIntervalSince1970: 1_776_400_000)

            try await database.dbQueue.write { db in
                try inheritedProject.insert(db)
                try insertSeriesMeeting(
                    event: seriesEvent(startDate: previousStart, recurrenceId: "20260415T090000Z"),
                    projectId: inheritedProject.id,
                    workspaceId: workspace.id,
                    createdAt: previousStart,
                    in: db
                )
            }

            let service = try await MeetingPersistenceService.createNew(
                store: TranscriptStore(),
                dbQueue: database.dbQueue,
                workspaceId: workspace.id,
                projectId: nil,
                initialName: "Current occurrence",
                allowsCalendarSeriesProjectInheritance: false,
                calendarEvent: seriesEvent(startDate: currentStart, recurrenceId: "20260416T090000Z")
            )
            await service.stop()

            let meeting = try fetchMeeting(id: service.meetingId, from: database.dbQueue)
            #expect(meeting.projectId == nil)
            #expect(service.projectId == nil)
        }

        @Test
        func materializedDraftInheritsProjectAndUpdatesViewModelContext() throws {
            let (database, workspace) = try makeDatabase()
            let inheritedProject = project(named: "Planning", workspaceId: workspace.id)
            let previousStart = Date(timeIntervalSince1970: 1_776_300_000)
            let currentStart = Date(timeIntervalSince1970: 1_776_400_000)

            try database.dbQueue.write { db in
                try inheritedProject.insert(db)
                try insertSeriesMeeting(
                    event: seriesEvent(startDate: previousStart, recurrenceId: "20260415T090000Z"),
                    projectId: inheritedProject.id,
                    workspaceId: workspace.id,
                    createdAt: previousStart,
                    in: db
                )
            }

            let previousWorkspace = AppSettings.shared.currentWorkspace
            AppSettings.shared.currentWorkspace = workspace
            defer { AppSettings.shared.currentWorkspace = previousWorkspace }

            let viewModel = CaptionViewModel()
            viewModel.beginDraftMeeting(
                from: seriesEvent(startDate: currentStart, recurrenceId: "20260416T090000Z"),
                dbQueue: database.dbQueue,
                workspaceURL: workspace.url
            )

            let meetingId = try #require(
                viewModel.materializeDraftMeeting()
            )
            let meeting = try fetchMeeting(id: meetingId, from: database.dbQueue)

            #expect(meeting.projectId == inheritedProject.id)
            #expect(viewModel.currentProjectId == inheritedProject.id)
            #expect(viewModel.currentProjectName == inheritedProject.name)
            #expect(
                viewModel.currentProjectURL
                    == workspace.url?.appending(path: inheritedProject.name, directoryHint: .isDirectory)
            )
        }

        @Test
        func materializedDraftPreservesExplicitNoProjectSelection() throws {
            let (database, workspace) = try makeDatabase()
            let inheritedProject = project(named: "Planning", workspaceId: workspace.id)
            let previousStart = Date(timeIntervalSince1970: 1_776_300_000)
            let currentStart = Date(timeIntervalSince1970: 1_776_400_000)

            try database.dbQueue.write { db in
                try inheritedProject.insert(db)
                try insertSeriesMeeting(
                    event: seriesEvent(startDate: previousStart, recurrenceId: "20260415T090000Z"),
                    projectId: inheritedProject.id,
                    workspaceId: workspace.id,
                    createdAt: previousStart,
                    in: db
                )
            }

            let previousWorkspace = AppSettings.shared.currentWorkspace
            AppSettings.shared.currentWorkspace = workspace
            defer { AppSettings.shared.currentWorkspace = previousWorkspace }

            let viewModel = CaptionViewModel()
            viewModel.beginDraftMeeting(
                from: seriesEvent(startDate: currentStart, recurrenceId: "20260416T090000Z"),
                dbQueue: database.dbQueue,
                workspaceURL: workspace.url
            )
            viewModel.setExplicitProjectContext(projectURL: nil, projectId: nil, projectName: nil)

            let meetingId = try #require(
                viewModel.materializeDraftMeeting()
            )
            let meeting = try fetchMeeting(id: meetingId, from: database.dbQueue)

            #expect(meeting.projectId == nil)
            #expect(viewModel.currentProjectId == nil)
            #expect(viewModel.currentProjectName == nil)
            #expect(viewModel.currentProjectURL == nil)
        }
    }

    private func makeDatabase() throws -> (database: AppDatabaseManager, workspace: WorkspaceRecord) {
        let database = try AppDatabaseManager(path: ":memory:")
        let workspace = WorkspaceRecord(
            id: .v7(),
            path: URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory).path,
            name: "Test Workspace",
            createdAt: .now,
            lastOpenedAt: .now
        )
        try database.dbQueue.write { db in
            try workspace.insert(db)
        }
        return (database, workspace)
    }

    private func project(named name: String, workspaceId: UUID) -> ProjectRecord {
        ProjectRecord(
            id: .v7(),
            workspaceId: workspaceId,
            path: name,
            createdAt: .now
        )
    }

    private func insertSeriesMeeting(
        event: CalendarEvent,
        projectId: UUID,
        workspaceId: UUID,
        createdAt: Date,
        in db: Database
    ) throws {
        guard let key = event.key else { throw CocoaError(.coderInvalidValue) }
        try CalendarEventRecord.upsert(event: event, now: createdAt, in: db)
        try MeetingRecord(
            id: .v7(),
            workspaceId: workspaceId,
            projectId: projectId,
            name: event.title,
            createdAt: createdAt,
            updatedAt: createdAt,
            calendarEventIcalUid: key.icalUid,
            calendarEventRecurrenceId: key.recurrenceId
        ).insert(db)
    }

    private func seriesEvent(startDate: Date, recurrenceId: String) -> CalendarEvent {
        CalendarEvent(
            id: "primary::series-\(recurrenceId)",
            calendarID: "primary",
            calendarName: "Primary",
            calendarColorHex: "#4285F4",
            platformId: "series-\(recurrenceId)",
            title: "Weekly planning",
            description: "",
            icalUid: "weekly-planning@google.com",
            recurrenceId: recurrenceId,
            startDate: startDate,
            endDate: startDate.addingTimeInterval(3600),
            isAllDay: false,
            conferenceURI: nil
        )
    }

    private func fetchMeeting(id: UUID, from dbQueue: DatabaseQueue) throws -> MeetingRecord {
        let record = try dbQueue.read { db in
            try MeetingRecord.fetchOne(db, key: id)
        }
        guard let record else { throw CocoaError(.coderInvalidValue) }
        return record
    }
#endif
