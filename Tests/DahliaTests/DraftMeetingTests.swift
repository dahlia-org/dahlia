import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct DraftMeetingTests {
        @Test
        func emptyDraftDoesNotPersistMeetingRecord() throws {
            let viewModel = CaptionViewModel()
            let database = try AppDatabaseManager(path: ":memory:")

            viewModel.beginDraftMeeting(
                dbQueue: database.dbQueue,
                vaultURL: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            )

            let meetingCount = try database.dbQueue.read(MeetingRecord.fetchCount)

            #expect(viewModel.hasDraftMeeting)
            #expect(viewModel.draftMeetingTitle == L10n.newMeeting)
            #expect(meetingCount == 0)
        }

        @Test
        func noteMaterializesDraftBeforeNavigation() throws {
            let viewModel = CaptionViewModel()
            let database = try AppDatabaseManager(path: ":memory:")
            let vaultURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            let vault = VaultRecord(
                id: .v7(),
                path: vaultURL.path,
                name: "Test Vault",
                createdAt: .now,
                lastOpenedAt: .now
            )
            try database.dbQueue.write { db in
                try vault.insert(db)
            }
            let previousVault = AppSettings.shared.currentVault
            AppSettings.shared.currentVault = vault
            defer { AppSettings.shared.currentVault = previousVault }

            viewModel.beginDraftMeeting(
                dbQueue: database.dbQueue,
                vaultURL: vaultURL
            )
            viewModel.noteText = "Keep this note"

            viewModel.clearCurrentMeeting()

            let persisted = try database.dbQueue.read { db in
                try (
                    MeetingRecord.fetchCount(db),
                    MeetingNoteRecord.fetchOne(db)?.text
                )
            }
            #expect(persisted.0 == 1)
            #expect(persisted.1 == "Keep this note")
        }

        @Test
        func draftPreservesActiveRecordingContext() throws {
            let viewModel = CaptionViewModel()
            let database = try AppDatabaseManager(path: ":memory:")
            let vaultURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            let vaultID = UUID.v7()
            try database.dbQueue.write { db in
                try VaultRecord(
                    id: vaultID,
                    path: vaultURL.path,
                    name: "Test Vault",
                    createdAt: .now,
                    lastOpenedAt: .now
                ).insert(db)
            }
            viewModel.createEmptyMeeting(
                dbQueue: database.dbQueue,
                projectURL: nil,
                vaultId: vaultID,
                projectId: nil,
                name: "Recording",
                vaultURL: vaultURL
            )
            let recordingMeetingID = try #require(viewModel.currentMeetingId)
            let recordingStore = viewModel.store

            viewModel.isListening = true
            viewModel.noteText = "Unsaved recording note"

            viewModel.beginDraftMeeting(
                dbQueue: database.dbQueue,
                vaultURL: vaultURL
            )

            let persistedNote = try database.dbQueue.read { db in
                try MeetingNoteRecord.fetchOne(db, key: recordingMeetingID)
            }

            #expect(viewModel.hasDraftMeeting)
            #expect(viewModel.currentMeetingId == nil)
            #expect(viewModel.recordingMeetingId == recordingMeetingID)
            #expect(persistedNote?.text == "Unsaved recording note")

            viewModel.returnToRecordingMeeting()

            #expect(viewModel.currentMeetingId == recordingMeetingID)
            #expect(viewModel.store === recordingStore)
        }

        @Test
        func finalizationRejectsDraftWithoutClearingSelection() {
            let viewModel = CaptionViewModel()
            let sidebarViewModel = SidebarViewModel()
            let selectedMeetingID = UUID.v7()
            sidebarViewModel.selectMeeting(selectedMeetingID)
            viewModel.isFinalizingRecording = true
            let coordinator = RecordingCoordinator(
                viewModel: viewModel,
                sidebarViewModel: sidebarViewModel,
                mainWindowNavigation: MainWindowNavigation(
                    openMainWindow: {},
                    openMainWindowWithoutActivation: {}
                ),
                onRecordingDidStart: {},
                onRecordingDidStop: {}
            )

            coordinator.createDraftMeeting()

            #expect(!viewModel.hasDraftMeeting)
            #expect(sidebarViewModel.selectedMeetingId == selectedMeetingID)
        }
    }
#endif
