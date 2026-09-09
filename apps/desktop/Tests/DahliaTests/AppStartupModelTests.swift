import Foundation
import GRDB
import os
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct AppStartupModelTests {
        @Test
        func startRunsOnceAndIgnoresLateProgress() async {
            let model = AppStartupModel()
            var calls = 0
            await model.start {
                calls += 1
                model.show(.updating)
                #expect(model.state == .working(.updating))
                model.show(.loadingVaults)
                model.show(.updating)
                #expect(model.state == .working(.loadingVaults))
                return nil
            }
            await model.start {
                calls += 1
                return nil
            }
            model.show(.preparing)
            #expect(calls == 1)
            #expect(model.isReady)
        }

        @Test
        func databaseFailureCannotContinueOrRetry() async {
            let model = AppStartupModel()
            await model.start { throw CocoaError(.fileReadCorruptFile) }
            guard case .failed(_, canContinue: false) = model.state else {
                Issue.record("Expected a blocking failure")
                return
            }
            model.continueAfterWarning()
            await model.start {
                Issue.record("Must not retry")
                return nil
            }
            #expect(!model.isReady)
        }

        @Test
        func restoreWarningRequiresAcknowledgement() async throws {
            let model = AppStartupModel()
            let warning = try #require(AppStartupModel.restoreWarning(.failed("Unable to restore")))
            var readyCalls = 0
            await model.start(onReady: { readyCalls += 1 }) { warning }
            #expect(readyCalls == 0)
            #expect(model.state == .failed(details: warning, canContinue: true))
            #expect(!model.isReady)
            model.continueAfterWarning()
            model.continueAfterWarning()
            #expect(model.isReady)
            #expect(readyCalls == 1)
            #expect(AppStartupModel.restoreWarning(.none) == nil)
            #expect(AppStartupModel.restoreWarning(.completed([])) == nil)
        }

        @Test
        func quitWaitsForOwnedWorkAndConcurrentStartDoesNotDuplicateIt() async {
            let model = AppStartupModel()
            let (started, startedContinuation) = AsyncStream<Void>.makeStream()
            let (release, releaseContinuation) = AsyncStream<Void>.makeStream()
            var finished = false
            var readyCalls = 0
            let launch = Task {
                await model.start(onReady: { readyCalls += 1 }) {
                    startedContinuation.yield(())
                    startedContinuation.finish()
                    for await _ in release {
                        break
                    }
                    #expect(!Task.isCancelled)
                    finished = true
                    #expect(!model.beginVaultLoading())
                    return nil
                }
            }
            for await _ in started {
                break
            }
            launch.cancel() // Closing the window cancels its caller, not the owned launch task.
            // The MainActor remains responsive while launch is suspended.
            #expect(!finished)
            #expect(!model.isReady)
            let duplicate = Task {
                await model.start {
                    Issue.record("Duplicate launch")
                    return nil
                }
            }
            let (quitting, quittingContinuation) = AsyncStream<Void>.makeStream()
            let termination = Task {
                quittingContinuation.yield(())
                quittingContinuation.finish()
                await model.prepareForTermination()
                #expect(finished)
            }
            for await _ in quitting {
                break
            }
            #expect(model.isTerminating)
            #expect(!finished)
            releaseContinuation.yield(())
            releaseContinuation.finish()
            await launch.value
            await duplicate.value
            await termination.value
            #expect(model.isTerminating)
            #expect(readyCalls == 0)
            model.cancelTermination()
            #expect(!model.isTerminating)
            #expect(readyCalls == 1)
        }

        @Test
        func quitCancelsVaultLoadingAfterDurablePreparation() async {
            let model = AppStartupModel()
            let (started, continuation) = AsyncStream<Void>.makeStream()
            var cancelled = false
            var readyCalls = 0
            let launch = Task {
                await model.start(onReady: { readyCalls += 1 }) {
                    #expect(model.beginVaultLoading())
                    continuation.yield(())
                    continuation.finish()
                    do {
                        // Stand in for a slow, cancellable network request, not a synchronization delay.
                        try await Task.sleep(for: .seconds(5))
                        Issue.record("Vault loading was not cancelled")
                    } catch is CancellationError {
                        cancelled = true
                    }
                    return nil
                }
            }
            for await _ in started {
                break
            }
            await model.prepareForTermination()
            await launch.value
            #expect(cancelled)
            #expect(readyCalls == 0)
        }

        @Test
        func quitDoesNotWaitForUncancellableVaultTokenRefresh() async {
            let model = AppStartupModel()
            let (started, continuation) = AsyncStream<Void>.makeStream()
            var release: CheckedContinuation<Void, Never>?
            var finished = false
            let launch = Task {
                await model.start {
                    #expect(model.beginVaultLoading())
                    await withCheckedContinuation {
                        release = $0
                        continuation.yield(())
                        continuation.finish()
                    }
                    #expect(Task.isCancelled)
                    finished = true
                    return nil
                }
            }
            for await _ in started {
                break
            }
            await model.prepareForTermination()
            #expect(!finished)
            release?.resume()
            await launch.value
        }

        @Test
        func quitBeforeLaunchPreventsDatabaseWork() async {
            let model = AppStartupModel()
            await model.prepareForTermination()
            await model.start {
                Issue.record("Launch started during quit")
                return nil
            }
            #expect(!model.isReady)
        }

        @Test
        func recordingAndMeetingCreationWaitForStartupAcknowledgement() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let vault = VaultRecord(id: .v7(), path: nil, name: "Test", createdAt: .now, lastOpenedAt: .now)
            try await database.dbQueue.write { try vault.insert($0) }
            let settings = AppSettings()
            settings.currentVault = vault
            let sidebar = SidebarViewModel(settings: settings)
            sidebar.setAppDatabase(database)
            defer { sidebar.setAppDatabase(nil) }
            let model = AppStartupModel()
            let viewModel = CaptionViewModel()
            let coordinator = RecordingCoordinator(
                viewModel: viewModel,
                sidebarViewModel: sidebar,
                mainWindowNavigation: MainWindowNavigation(openMainWindow: {}, openMainWindowWithoutActivation: {}),
                onRecordingDidStart: {},
                onRecordingDidStop: {},
                isAppReady: { model.isReady && !model.isTerminating }
            )
            #expect(!coordinator.canStartNewMeeting)
            await model.start { "Restore warning" }
            coordinator.createEmptyMeeting()
            coordinator.createDraftMeeting()
            #expect(!viewModel.hasDraftMeeting)
            #expect(try await database.dbQueue.read(MeetingRecord.fetchCount) == 0)
            #expect(!coordinator.canStartNewMeeting)
            model.continueAfterWarning()
            #expect(coordinator.canStartNewMeeting)
            await model.prepareForTermination()
            #expect(!coordinator.canStartNewMeeting)
        }

        @Test
        func partialRestoreShowsBothSuccessfulAndFailedVaults() throws {
            let request = VaultBackupRestoreRequest(
                sourceVaultId: .v7(), targetVaultId: .v7(), mode: .newVault, name: "Restored vault"
            )
            let success = VaultBackupRestoreResult(request: request, error: nil)
            let failure = VaultBackupRestoreResult(request: request, error: "Disk full")
            #expect(AppStartupModel.restoreWarning(.completed([success])) == nil)
            let warning = try #require(AppStartupModel.restoreWarning(.completed([success, failure])))
            #expect(warning.contains(success.localizedMessage))
            #expect(warning.contains(failure.localizedMessage))
        }

        @Test
        func prepareDatabaseReportsRestoreFailureWithoutLosingExistingData() async throws {
            let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appending(path: "dahlia.sqlite")
            let initial = try AppDatabaseManager(path: url.path)
            let vaultID = UUID.v7()
            try await initial.dbQueue.write { db in
                try db.execute(
                    sql: "INSERT INTO vaults (id, path, name, createdAt, lastOpenedAt) VALUES (?, '/tmp/preserved', 'Preserved', ?, ?)",
                    arguments: [vaultID, Date.now, Date.now]
                )
            }
            try initial.close()
            let marker = BackupService.pendingRestoreURL(applicationSupportURL: directory)
            try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("invalid restore request".utf8).write(to: marker)
            var phases: [AppStartupModel.Phase] = []
            let (db, outcome) = try await AppStartupModel.prepareDatabase(
                applicationSupportURL: directory, databaseURL: url
            ) { phases.append($0) }
            #expect(phases == [.restoring, .preparing])
            #expect(AppStartupModel.restoreWarning(outcome) != nil)
            #expect(try await db.dbQueue
                .read { try String.fetchOne($0, sql: "SELECT name FROM vaults WHERE id = ?", arguments: [vaultID]) } == "Preserved")
            try db.close()
        }

        @Test
        func prepareDatabaseCreatesAndReopensWithoutReportingUpdate() async throws {
            let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appending(path: "dahlia.sqlite")
            for _ in 0 ..< 2 {
                let (db, outcome) = try await AppStartupModel.prepareDatabase(
                    applicationSupportURL: directory,
                    databaseURL: url
                ) { phase in
                    #expect(phase == .preparing)
                }
                #expect(outcome == .none)
                #expect(try await db.dbQueue.read { try AppDatabaseManager.migrator.hasCompletedMigrations($0) })
                try db.close()
            }
        }

        @Test
        func migrationNotificationOnlyRunsForPendingMigrations() throws {
            let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appending(path: "dahlia.sqlite")
            let queue = try DatabaseQueue(path: url.path)
            try AppDatabaseManager.migrator.migrate(queue, upTo: "v41_vaultAISettingsBackfill")
            try queue.close()
            let notifications = OSAllocatedUnfairLock(initialState: 0)
            let onMigration: @Sendable () -> Void = { notifications.withLock { $0 += 1 } }
            let upgraded = try AppDatabaseManager(path: url.path, onMigration: onMigration)
            #expect(notifications.withLock { $0 } == 1)
            try upgraded.close()
            let reopened = try AppDatabaseManager(path: url.path, onMigration: onMigration)
            #expect(notifications.withLock { $0 } == 1)
            try reopened.close()
        }
    }
#endif
