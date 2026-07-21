import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct CaptionViewModelBatchRetryTests {
        @Test
        func newConfirmationDefaultsToManualSelectedLanguage() {
            let confirmation = BatchTranscriptionConfirmation(
                sessionId: .v7(),
                meetingId: .v7(),
                suggestedLocaleIdentifier: "ja_JP",
                retainAudioAfterBatch: true
            )

            #expect(confirmation.initialLanguageSelection == .manual(localeIdentifier: "ja_JP"))
        }

        @Test
        func failedAutomaticBatchRetryPresentsLanguageSelection() async throws {
            let batch = try BatchAudioTestFixture(
                name: "failed-auto-retry-selection",
                endedAt: Date(timeIntervalSince1970: 1_776_384_001),
                duration: 1,
                retainAudioAfterBatch: true
            )
            defer { batch.removeFiles() }
            try await markBatchFailed(batch)

            let viewModel = CaptionViewModel()
            viewModel.configureBatchTranscription(
                dbQueue: batch.database.dbQueue,
                managedRootURL: batch.managedRootURL,
                recoverExistingSessions: false
            )
            viewModel.loadMeeting(
                batch.meeting.id,
                dbQueue: batch.database.dbQueue,
                projectURL: nil,
                projectId: nil,
                vaultURL: batch.vaultURL
            )
            #expect(await waitUntil {
                if case .failed = viewModel.batchTranscriptionState { true } else { false }
            })

            viewModel.retryBatchTranscription()

            let confirmation = try #require(viewModel.pendingBatchTranscriptionConfirmation)
            #expect(confirmation.sessionId == batch.session.id)
            #expect(
                confirmation.initialLanguageSelection == .automatic(fallbackLocaleIdentifier: "en_GB")
            )
            #expect(confirmation.retainAudioAfterBatch)
        }

        private func markBatchFailed(_ batch: BatchAudioTestFixture) async throws {
            try await batch.database.dbQueue.write { db in
                guard var session = try RecordingSessionRecord.fetchOne(db, key: batch.session.id) else {
                    throw CocoaError(.fileNoSuchFile)
                }
                session.batchLanguageDetectionMode = .automatic
                session.batchSelectedLocaleIdentifier = "en_GB"
                session.batchLastError = L10n.batchLanguageDetectionFailed
                session.batchLastAttemptAt = batch.now
                session.batchAttemptCount = 1
                try session.update(db)
            }
        }

        private func waitUntil(
            timeout: Duration = .seconds(15),
            condition: () -> Bool
        ) async -> Bool {
            let clock = ContinuousClock()
            let deadline = clock.now + timeout
            while clock.now < deadline {
                if condition() { return true }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return condition()
        }
    }
#endif
