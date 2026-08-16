import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct SidebarViewModelSelectedMeetingDetailTests {
        @Test(.timeLimit(.minutes(3)))
        func rapidSelectionChangePublishesOnlyLatestMeetingDetail() async throws {
            let fixture = try SidebarViewModelMeetingListFixture()
            defer { fixture.stop() }
            let firstID = UUID.v7()
            let secondID = UUID.v7()
            try await fixture.manager.dbQueue.write { db in
                try insertMeeting(id: firstID, vaultId: fixture.vault.id, name: "First", in: db)
                try insertMeeting(id: secondID, vaultId: fixture.vault.id, name: "Second", in: db)
            }
            let viewModel = fixture.makeViewModel()
            defer { viewModel.setAppDatabase(nil) }

            viewModel.selectMeeting(firstID)
            viewModel.selectMeeting(secondID)

            #expect(ContentView.isMeetingSelectionPending(
                selectedMeetingID: secondID,
                currentMeetingID: firstID
            ))
            #expect(await waitUntil { viewModel.selectedMeetingDetail?.meetingId == secondID })
            #expect(viewModel.selectedMeetingIds == Set([secondID]))
            #expect(!ContentView.isMeetingSelectionPending(
                selectedMeetingID: secondID,
                currentMeetingID: secondID
            ))
        }

        @Test(.timeLimit(.minutes(3)))
        func databaseChangeRejectsStaleSelectedMeetingDetail() async throws {
            let fixture = try SidebarViewModelMeetingListFixture()
            defer { fixture.stop() }
            let meetingID = UUID.v7()
            try await fixture.manager.dbQueue.write { db in
                try insertMeeting(id: meetingID, vaultId: fixture.vault.id, name: "Stale", in: db)
            }
            let viewModel = fixture.makeViewModel()

            viewModel.selectMeeting(meetingID)
            viewModel.setAppDatabase(nil)
            await Task.yield()

            #expect(viewModel.selectedMeetingDetail == nil)
            #expect(viewModel.selectedMeetingIds.isEmpty)
        }

        @Test(.timeLimit(.minutes(3)))
        func selectedMeetingDetailFailureCanBeRetried() async throws {
            let fixture = try SidebarViewModelMeetingListFixture()
            defer { fixture.stop() }
            let meetingID = UUID.v7()
            try await fixture.manager.dbQueue.write { db in
                try insertMeeting(id: meetingID, vaultId: fixture.vault.id, name: "Retry", in: db)
            }
            let viewModel = fixture.makeViewModel()
            defer { viewModel.setAppDatabase(nil) }
            try await fixture.manager.dbQueue.write { db in
                try db.execute(sql: "ALTER TABLE meeting_tags RENAME TO unavailable_meeting_tags")
            }

            viewModel.selectMeeting(meetingID)
            #expect(await waitUntil { viewModel.selectedMeetingDetailLoadError != nil })
            #expect(viewModel.selectedMeetingDetail == nil)

            try await fixture.manager.dbQueue.write { db in
                try db.execute(sql: "ALTER TABLE unavailable_meeting_tags RENAME TO meeting_tags")
            }
            viewModel.startSelectedMeetingObservationIfNeeded()

            #expect(await waitUntil { viewModel.selectedMeetingDetail?.meetingId == meetingID })
            #expect(viewModel.selectedMeetingDetailLoadError == nil)
        }

        @Test(.timeLimit(.minutes(3)))
        func meetingExistenceIsScopedToCurrentVault() async throws {
            let fixture = try SidebarViewModelMeetingListFixture()
            defer { fixture.stop() }
            let meetingID = UUID.v7()
            try await fixture.manager.dbQueue.write { db in
                try insertMeeting(id: meetingID, vaultId: fixture.vault.id, name: "Current vault", in: db)
            }
            let viewModel = fixture.makeViewModel()
            defer { viewModel.setAppDatabase(nil) }

            #expect(await viewModel.containsMeeting(id: meetingID))
            let missingMeetingExists = await viewModel.containsMeeting(id: UUID.v7())
            #expect(!missingMeetingExists)
        }

        private func waitUntil(
            timeout: Duration = testPollTimeout,
            _ predicate: @MainActor () -> Bool
        ) async -> Bool {
            await pollUntil(timeout: timeout) { predicate() }
        }
    }
#endif
