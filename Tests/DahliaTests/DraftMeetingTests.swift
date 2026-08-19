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
            let draftID = try #require(viewModel.draftMeeting?.id)
            viewModel.noteText = "Keep this note"

            viewModel.clearCurrentMeeting()
            let materialization = try #require(viewModel.latestDraftMaterialization)

            let persisted = try database.dbQueue.read { db in
                try (
                    MeetingRecord.fetchCount(db),
                    MeetingNoteRecord.fetchOne(db)?.text,
                    MeetingRecord.fetchOne(db)?.id
                )
            }
            #expect(persisted.0 == 1)
            #expect(persisted.1 == "Keep this note")
            #expect(persisted.2 == materialization.meetingID)
            #expect(materialization.draftID == draftID)
        }

        @Test
        func replacingNotedDraftPublishesMaterializationBeforeTheNextDraft() throws {
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

            viewModel.beginDraftMeeting(dbQueue: database.dbQueue, vaultURL: vaultURL)
            let firstDraftID = try #require(viewModel.draftMeeting?.id)
            viewModel.noteText = "Persist the first draft"

            viewModel.beginDraftMeeting(dbQueue: database.dbQueue, vaultURL: vaultURL)

            let materialization = try #require(viewModel.latestDraftMaterialization)
            #expect(materialization.draftID == firstDraftID)
            #expect(viewModel.draftMeeting?.id != firstDraftID)
            #expect(try database.dbQueue.read(MeetingRecord.fetchCount) == 1)
            #expect(try database.dbQueue.read { db in
                try MeetingRecord.fetchOne(db)?.id
            } == materialization.meetingID)
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

        @Test
        func createsDraftInSelectedProject() throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let vaultURL = FileManager.default.temporaryDirectory
                .appending(path: "dahlia-project-draft-\(UUID.v7())", directoryHint: .isDirectory)
            let vault = VaultRecord(
                id: .v7(),
                path: vaultURL.path,
                name: "Test",
                createdAt: .now,
                lastOpenedAt: .now
            )
            let settings = AppSettings()
            settings.currentVault = vault
            let sidebarViewModel = SidebarViewModel(settings: settings)
            sidebarViewModel.setAppDatabase(database)
            defer { sidebarViewModel.setAppDatabase(nil) }
            let viewModel = CaptionViewModel()
            let navigation = MainWindowNavigation(
                openMainWindow: {},
                openMainWindowWithoutActivation: {}
            )
            let coordinator = RecordingCoordinator(
                viewModel: viewModel,
                sidebarViewModel: sidebarViewModel,
                mainWindowNavigation: navigation,
                onRecordingDidStart: {},
                onRecordingDidStop: {}
            )
            let project = ProjectOverviewItem(
                projectId: .v7(),
                projectName: "Parent/Project",
                createdAt: .now,
                meetingCount: 0
            )

            coordinator.createDraftMeeting(in: project)

            #expect(viewModel.draftMeeting?.projectId == project.projectId)
            #expect(viewModel.draftMeeting?.projectName == project.projectName)
            #expect(viewModel.draftMeeting?.projectURL == vaultURL.appending(path: project.projectName, directoryHint: .isDirectory))
            guard case let .meetingDraft(navigationDraft, noteText) = navigation.currentLocation else {
                Issue.record("Expected meeting draft navigation")
                return
            }
            #expect(navigationDraft == viewModel.draftMeeting)
            #expect(noteText.isEmpty)
        }

        @Test
        func restoresCalendarDraftWithIdentityMetadataAndNote() throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let viewModel = CaptionViewModel()
            let vaultURL = FileManager.default.temporaryDirectory
            let event = CalendarEvent(
                id: "calendar::event",
                calendarID: "calendar",
                calendarName: "Work",
                calendarColorHex: nil,
                platformId: "event",
                title: "Design review",
                description: "",
                icalUid: "event@example.com",
                startDate: Date(timeIntervalSince1970: 1_776_384_000),
                endDate: Date(timeIntervalSince1970: 1_776_387_600),
                isAllDay: false,
                conferenceURI: nil
            )
            let draft = DraftMeeting(
                id: .v7(),
                title: "Renamed review",
                linkedCalendarEvent: event,
                projectId: .v7(),
                projectName: "Customer"
            )

            viewModel.restoreDraftMeeting(
                draft,
                noteText: "Questions to ask",
                dbQueue: database.dbQueue,
                vaultURL: vaultURL
            )

            #expect(viewModel.draftMeeting == draft)
            #expect(viewModel.noteText == "Questions to ask")
            #expect(viewModel.currentProjectId == draft.projectId)
            #expect(viewModel.currentProjectName == draft.projectName)
            #expect(try database.dbQueue.read(MeetingRecord.fetchCount) == 0)
        }
    }
#endif
