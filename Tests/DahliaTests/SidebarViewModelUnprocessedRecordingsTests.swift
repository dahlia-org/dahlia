import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct SidebarViewModelUnprocessedRecordingsTests {
        @Test
        func refreshSurfacesDatabaseFailure() async throws {
            let fixture = try SidebarViewModelMeetingListFixture()
            defer { fixture.stop() }
            let viewModel = fixture.makeViewModel()
            defer { viewModel.setAppDatabase(nil) }
            try await fixture.manager.dbQueue.write { db in
                try db.execute(sql: "DROP TABLE recording_audio_segment_ranges")
            }

            await viewModel.refreshUnprocessedRecordings()

            #expect(viewModel.unprocessedRecordingItems.isEmpty)
            #expect(viewModel.unprocessedRecordingsError != nil)
            #expect(!viewModel.isLoadingUnprocessedRecordings)
        }

        @Test
        func staleDiscardFailureDoesNotAppearAfterVaultChanges() async throws {
            let fixture = try SidebarViewModelMeetingListFixture()
            defer { fixture.stop() }
            let settings = AppSettings()
            settings.currentVault = fixture.vault
            let gate = SidebarDiscardGate()
            let viewModel = SidebarViewModel(settings: settings) { _, _, _ in
                await gate.wait()
                throw SidebarDiscardTestError.failed
            }
            viewModel.setAppDatabase(fixture.manager)
            defer { viewModel.setAppDatabase(nil) }

            let discardTask = Task {
                await viewModel.discardUnprocessedRecording(Self.discardItem(vaultId: fixture.vault.id))
            }
            #expect(await gate.waitUntilBlocked())
            settings.currentVault = nil
            viewModel.setAppDatabase(nil)
            await gate.release()
            await discardTask.value

            #expect(viewModel.unprocessedRecordingsError == nil)
        }

        @Test
        func staleVaultItemIsRejectedBeforeDiscardStarts() async throws {
            let fixture = try SidebarViewModelMeetingListFixture()
            defer { fixture.stop() }
            let settings = AppSettings()
            settings.currentVault = fixture.vault
            let viewModel = SidebarViewModel(settings: settings) { _, _, _ in
                Issue.record("Discard must not start for an item from another Vault")
                return true
            }
            viewModel.setAppDatabase(fixture.manager)
            defer { viewModel.setAppDatabase(nil) }
            settings.currentVault = VaultRecord(
                id: .v7(),
                path: fixture.vault.path,
                name: "Other",
                createdAt: .now,
                lastOpenedAt: .now
            )

            await viewModel.discardUnprocessedRecording(Self.discardItem(vaultId: fixture.vault.id))

            #expect(viewModel.unprocessedRecordingsError == nil)
        }

        @Test
        func successfulDiscardRefreshesAfterOverlappingSameVaultRefresh() async throws {
            let fixture = try SidebarViewModelMeetingListFixture()
            defer { fixture.stop() }
            let settings = AppSettings()
            settings.currentVault = fixture.vault
            let gate = SidebarDiscardGate()
            let viewModel = SidebarViewModel(settings: settings) { _, _, _ in
                await gate.wait()
                return true
            }
            viewModel.setAppDatabase(fixture.manager)
            defer { viewModel.setAppDatabase(nil) }

            let discardTask = Task {
                await viewModel.discardUnprocessedRecording(Self.discardItem(vaultId: fixture.vault.id))
            }
            #expect(await gate.waitUntilBlocked())
            await viewModel.refreshUnprocessedRecordings()
            try await fixture.manager.dbQueue.write { db in
                try db.execute(sql: "DROP TABLE recording_audio_segment_ranges")
            }
            await gate.release()
            await discardTask.value

            #expect(viewModel.unprocessedRecordingsError != nil)
        }

        private static func discardItem(vaultId: UUID) -> BackupPreflightItem {
            BackupPreflightItem(
                sessionId: .v7(),
                meetingId: .v7(),
                vaultId: vaultId,
                meetingName: "Discard",
                startedAt: .now,
                state: .failed,
                failureMessage: "damaged",
                canTranscribe: false
            )
        }
    }

    private enum SidebarDiscardTestError: Error {
        case failed
    }

    private actor SidebarDiscardGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var isBlocked = false

        func wait() async {
            isBlocked = true
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }

        func waitUntilBlocked() async -> Bool {
            await pollUntil { self.isBlocked }
        }

        func release() {
            continuation?.resume()
            continuation = nil
            isBlocked = false
        }
    }
#endif
