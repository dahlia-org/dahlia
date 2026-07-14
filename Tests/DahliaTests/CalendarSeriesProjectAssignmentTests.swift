import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct CalendarSeriesProjectAssignmentTests {
        @Test
        func newMeetingInheritsProjectFromMostRecentEarlierOccurrence() async throws {
            let (database, vault) = try makeDatabase()
            let olderProject = project(named: "Older project", vaultId: vault.id)
            let recentProject = project(named: "Recent project", vaultId: vault.id)
            let futureProject = project(named: "Future project", vaultId: vault.id)
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
                    vaultId: vault.id,
                    createdAt: recentStart.addingTimeInterval(100),
                    in: db
                )
                try insertSeriesMeeting(
                    event: seriesEvent(startDate: recentStart, recurrenceId: "20260415T090000Z"),
                    projectId: recentProject.id,
                    vaultId: vault.id,
                    createdAt: olderStart,
                    in: db
                )
                try insertSeriesMeeting(
                    event: seriesEvent(startDate: futureStart, recurrenceId: "20260417T090000Z"),
                    projectId: futureProject.id,
                    vaultId: vault.id,
                    createdAt: futureStart,
                    in: db
                )
            }

            let service = try MeetingPersistenceService(
                store: TranscriptStore(),
                dbQueue: database.dbQueue,
                vaultId: vault.id,
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
        func newMeetingSkipsMostRecentProjectWhenItsFolderIsMissing() async throws {
            let (database, vault) = try makeDatabase()
            let availableProject = project(named: "Available project", vaultId: vault.id)
            var unavailableProject = project(named: "Missing project", vaultId: vault.id)
            unavailableProject.missingOnDisk = true
            let missingProject = unavailableProject
            let olderStart = Date(timeIntervalSince1970: 1_776_200_000)
            let recentStart = Date(timeIntervalSince1970: 1_776_300_000)
            let currentStart = Date(timeIntervalSince1970: 1_776_400_000)

            try await database.dbQueue.write { db in
                try availableProject.insert(db)
                try missingProject.insert(db)
                try insertSeriesMeeting(
                    event: seriesEvent(startDate: olderStart, recurrenceId: "20260414T090000Z"),
                    projectId: availableProject.id,
                    vaultId: vault.id,
                    createdAt: olderStart,
                    in: db
                )
                try insertSeriesMeeting(
                    event: seriesEvent(startDate: recentStart, recurrenceId: "20260415T090000Z"),
                    projectId: missingProject.id,
                    vaultId: vault.id,
                    createdAt: recentStart,
                    in: db
                )
            }

            let service = try MeetingPersistenceService(
                store: TranscriptStore(),
                dbQueue: database.dbQueue,
                vaultId: vault.id,
                projectId: nil,
                initialName: "Current occurrence",
                calendarEvent: seriesEvent(startDate: currentStart, recurrenceId: "20260416T090000Z")
            )
            await service.stop()

            let meeting = try fetchMeeting(id: service.meetingId, from: database.dbQueue)
            #expect(meeting.projectId == availableProject.id)
            #expect(service.projectId == availableProject.id)
        }

        @Test
        func explicitlySelectedProjectOverridesSeriesProject() async throws {
            let (database, vault) = try makeDatabase()
            let seriesProject = project(named: "Series project", vaultId: vault.id)
            let selectedProject = project(named: "Selected project", vaultId: vault.id)
            let previousStart = Date(timeIntervalSince1970: 1_776_300_000)
            let currentStart = Date(timeIntervalSince1970: 1_776_400_000)

            try await database.dbQueue.write { db in
                try seriesProject.insert(db)
                try selectedProject.insert(db)
                try insertSeriesMeeting(
                    event: seriesEvent(startDate: previousStart, recurrenceId: "20260415T090000Z"),
                    projectId: seriesProject.id,
                    vaultId: vault.id,
                    createdAt: previousStart,
                    in: db
                )
            }

            let service = try MeetingPersistenceService(
                store: TranscriptStore(),
                dbQueue: database.dbQueue,
                vaultId: vault.id,
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
            let (database, vault) = try makeDatabase()
            let inheritedProject = project(named: "Planning", vaultId: vault.id)
            let previousStart = Date(timeIntervalSince1970: 1_776_300_000)
            let currentStart = Date(timeIntervalSince1970: 1_776_400_000)

            try await database.dbQueue.write { db in
                try inheritedProject.insert(db)
                try insertSeriesMeeting(
                    event: seriesEvent(startDate: previousStart, recurrenceId: "20260415T090000Z"),
                    projectId: inheritedProject.id,
                    vaultId: vault.id,
                    createdAt: previousStart,
                    in: db
                )
            }

            let service = try MeetingPersistenceService(
                store: TranscriptStore(),
                dbQueue: database.dbQueue,
                vaultId: vault.id,
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
            let (database, vault) = try makeDatabase()
            let inheritedProject = project(named: "Planning", vaultId: vault.id)
            let previousStart = Date(timeIntervalSince1970: 1_776_300_000)
            let currentStart = Date(timeIntervalSince1970: 1_776_400_000)

            try database.dbQueue.write { db in
                try inheritedProject.insert(db)
                try insertSeriesMeeting(
                    event: seriesEvent(startDate: previousStart, recurrenceId: "20260415T090000Z"),
                    projectId: inheritedProject.id,
                    vaultId: vault.id,
                    createdAt: previousStart,
                    in: db
                )
            }

            let previousVault = AppSettings.shared.currentVault
            AppSettings.shared.currentVault = vault
            defer { AppSettings.shared.currentVault = previousVault }

            let viewModel = CaptionViewModel()
            viewModel.beginDraftMeeting(
                from: seriesEvent(startDate: currentStart, recurrenceId: "20260416T090000Z"),
                dbQueue: database.dbQueue,
                vaultURL: vault.url
            )

            let meetingId = try #require(viewModel.materializeDraftMeeting())
            let meeting = try fetchMeeting(id: meetingId, from: database.dbQueue)

            #expect(meeting.projectId == inheritedProject.id)
            #expect(viewModel.currentProjectId == inheritedProject.id)
            #expect(viewModel.currentProjectName == inheritedProject.name)
            #expect(
                viewModel.currentProjectURL
                    == vault.url.appending(path: inheritedProject.name, directoryHint: .isDirectory)
            )
        }

        @Test
        func materializedDraftPreservesExplicitNoProjectSelection() throws {
            let (database, vault) = try makeDatabase()
            let inheritedProject = project(named: "Planning", vaultId: vault.id)
            let previousStart = Date(timeIntervalSince1970: 1_776_300_000)
            let currentStart = Date(timeIntervalSince1970: 1_776_400_000)

            try database.dbQueue.write { db in
                try inheritedProject.insert(db)
                try insertSeriesMeeting(
                    event: seriesEvent(startDate: previousStart, recurrenceId: "20260415T090000Z"),
                    projectId: inheritedProject.id,
                    vaultId: vault.id,
                    createdAt: previousStart,
                    in: db
                )
            }

            let previousVault = AppSettings.shared.currentVault
            AppSettings.shared.currentVault = vault
            defer { AppSettings.shared.currentVault = previousVault }

            let viewModel = CaptionViewModel()
            viewModel.beginDraftMeeting(
                from: seriesEvent(startDate: currentStart, recurrenceId: "20260416T090000Z"),
                dbQueue: database.dbQueue,
                vaultURL: vault.url
            )
            viewModel.setExplicitProjectContext(projectURL: nil, projectId: nil, projectName: nil)

            let meetingId = try #require(viewModel.materializeDraftMeeting())
            let meeting = try fetchMeeting(id: meetingId, from: database.dbQueue)

            #expect(meeting.projectId == nil)
            #expect(viewModel.currentProjectId == nil)
            #expect(viewModel.currentProjectName == nil)
            #expect(viewModel.currentProjectURL == nil)
        }
    }

    private func makeDatabase() throws -> (database: AppDatabaseManager, vault: VaultRecord) {
        let database = try AppDatabaseManager(path: ":memory:")
        let vault = VaultRecord(
            id: .v7(),
            path: URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory).path,
            name: "Test Vault",
            createdAt: .now,
            lastOpenedAt: .now
        )
        try database.dbQueue.write { db in
            try vault.insert(db)
        }
        return (database, vault)
    }

    private func project(named name: String, vaultId: UUID) -> ProjectRecord {
        ProjectRecord(
            id: .v7(),
            vaultId: vaultId,
            name: name,
            createdAt: .now
        )
    }

    private func insertSeriesMeeting(
        event: CalendarEvent,
        projectId: UUID,
        vaultId: UUID,
        createdAt: Date,
        in db: Database
    ) throws {
        guard let key = event.key else { throw CocoaError(.coderInvalidValue) }
        try CalendarEventRecord.upsert(event: event, now: createdAt, in: db)
        try MeetingRecord(
            id: .v7(),
            vaultId: vaultId,
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
