import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct ProjectDetailViewModelTests {
        @Test
        func newerReloadReplacesAnInFlightListLoad() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let vault = VaultRecord(
                id: .v7(),
                path: "/tmp/project-detail-view-model-tests",
                name: "Test",
                createdAt: .now,
                lastOpenedAt: .now
            )
            let firstProjectID = UUID.v7()
            let secondProjectID = UUID.v7()
            try await database.dbQueue.write { db in
                try vault.insert(db)
                try Self.project(id: firstProjectID, vaultID: vault.id, name: "First").insert(db)
                try Self.project(id: secondProjectID, vaultID: vault.id, name: "Second").insert(db)
                try Self.meeting(vaultID: vault.id, projectID: firstProjectID, name: "First meeting").insert(db)
                try Self.meeting(vaultID: vault.id, projectID: secondProjectID, name: "Second meeting").insert(db)
            }

            let databaseAccessStarted = AsyncStream<Void>.makeStream()
            let releaseDatabase = DispatchSemaphore(value: 0)
            let blocker = Task.detached {
                try await database.dbQueue.write { _ in
                    databaseAccessStarted.continuation.yield()
                    releaseDatabase.wait()
                }
                databaseAccessStarted.continuation.finish()
            }
            var databaseAccessIterator = databaseAccessStarted.stream.makeAsyncIterator()
            _ = await databaseAccessIterator.next()
            defer { releaseDatabase.signal() }

            let model = ProjectDetailViewModel()
            let firstLoad = Task {
                await model.reload(projectIDs: [firstProjectID], vaultID: vault.id, dbQueue: database.dbQueue)
            }
            #expect(await pollUntil { model.isLoadingList })
            let secondLoad = Task {
                await model.reload(projectIDs: [secondProjectID], vaultID: vault.id, dbQueue: database.dbQueue)
            }
            #expect(await pollUntil { model.isLoadingList && model.listItems.isEmpty })

            releaseDatabase.signal()
            await firstLoad.value
            await secondLoad.value
            try await blocker.value

            #expect(model.listItems.map(\.meetingName) == ["Second meeting"])
            #expect(!model.isLoadingList)
        }

        @Test
        func calendarReplacementClearsOldItemsAndReportsTheCurrentError() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let vault = VaultRecord(
                id: .v7(),
                path: "/tmp/project-detail-calendar-tests",
                name: "Test",
                createdAt: .now,
                lastOpenedAt: .now
            )
            let projectID = UUID.v7()
            let meetingDate = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 8, day: 10)))
            try await database.dbQueue.write { db in
                try vault.insert(db)
                try Self.project(id: projectID, vaultID: vault.id, name: "Project").insert(db)
                try Self.meeting(
                    vaultID: vault.id,
                    projectID: projectID,
                    name: "August meeting",
                    createdAt: meetingDate
                ).insert(db)
            }

            let model = ProjectDetailViewModel()
            await model.loadCalendar(
                containing: meetingDate,
                projectIDs: [projectID],
                vaultID: vault.id,
                dbQueue: database.dbQueue
            )
            #expect(model.calendarItems.map(\.meetingName) == ["August meeting"])

            let invalidDatabase = try DatabaseQueue()
            await model.loadCalendar(
                containing: meetingDate.addingTimeInterval(32 * 24 * 60 * 60),
                projectIDs: [projectID],
                vaultID: vault.id,
                dbQueue: invalidDatabase
            )

            #expect(model.calendarItems.isEmpty)
            #expect(model.calendarError != nil)
            #expect(!model.isCalendarLimited)
        }

        private nonisolated static func project(id: UUID, vaultID: UUID, name: String) -> ProjectRecord {
            ProjectRecord(
                id: id,
                vaultId: vaultID,
                parentProjectId: nil,
                name: name,
                createdAt: .now,
                projectType: .undefined
            )
        }

        private nonisolated static func meeting(
            vaultID: UUID,
            projectID: UUID,
            name: String,
            createdAt: Date = .now
        ) -> MeetingRecord {
            MeetingRecord(
                id: .v7(),
                vaultId: vaultID,
                projectId: projectID,
                name: name,
                description: "",
                createdAt: createdAt,
                updatedAt: createdAt
            )
        }
    }
#endif
