import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct CaptionViewModelBatchRetryTests {
        @Test
        func retainedCompletedAudioOffersRetranscription() async throws {
            let batch = try BatchAudioTestFixture(
                name: "retained-completed-audio",
                endedAt: Date(timeIntervalSince1970: 1_776_384_001),
                duration: 1,
                retainAudioAfterBatch: true,
                batchCompletedAt: Date(timeIntervalSince1970: 1_776_384_002)
            )
            defer { batch.removeFiles() }
            try await batch.recordMicrophoneAudio()

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
            #expect(await waitUntil { viewModel.canRetranscribeBatchAudio })

            viewModel.presentBatchRetranscriptionConfirmation()

            let confirmation = try #require(viewModel.pendingBatchTranscriptionConfirmation)
            #expect(confirmation.isRetranscription)
            #expect(confirmation.sessionId == batch.session.id)
            #expect(confirmation.retainAudioAfterBatch)
            guard case let .retranscription(sessionIds) = confirmation.purpose else {
                Issue.record("Expected a retranscription confirmation")
                return
            }
            #expect(sessionIds == [batch.session.id])
        }

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
                retainAudioAfterBatch: false
            )
            defer { batch.removeFiles() }
            try await batch.recordMicrophoneAudio()
            try await markBatchFailed(batch)

            let viewModel = CaptionViewModel()
            viewModel.supportedLocales = [Locale(identifier: "en_GB"), Locale(identifier: "ja_JP")]
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
                if case .failed = viewModel.batchTranscriptionState {
                    viewModel.canRetranscribeBatchAudio
                } else {
                    false
                }
            })
            #expect(viewModel.batchTranscriptionFailureMessage == L10n.batchLanguageDetectionFailed)

            viewModel.presentAvailableBatchRetranscription()

            let confirmation = try #require(viewModel.pendingBatchTranscriptionConfirmation)
            #expect(confirmation.sessionId == batch.session.id)
            #expect(confirmation.initialLanguageSelection == .automatic)
            #expect(!confirmation.retainAudioAfterBatch)
            #expect(confirmation.automaticLanguageCandidateSnapshot?.identifierSet == ["en", "ja"])
        }

        @Test
        func failedRetranscriptionOffersRetryAndCanKeepCurrentTranscript() async throws {
            let completedAt = Date(timeIntervalSince1970: 1_776_384_002)
            let batch = try BatchAudioTestFixture(
                name: "failed-retranscription",
                endedAt: Date(timeIntervalSince1970: 1_776_384_001),
                duration: 1,
                retainAudioAfterBatch: true,
                batchCompletedAt: completedAt
            )
            defer { batch.removeFiles() }
            try await batch.recordMicrophoneAudio()
            try await batch.database.dbQueue.write { db in
                guard var session = try RecordingSessionRecord.fetchOne(db, key: batch.session.id) else {
                    throw CocoaError(.fileNoSuchFile)
                }
                session.batchLastAttemptAt = completedAt.addingTimeInterval(1)
                session.batchLastError = "retranscription failed"
                try session.update(db)
            }

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
                if case .retranscriptionFailed = viewModel.batchTranscriptionState {
                    viewModel.canRetranscribeBatchAudio
                } else {
                    false
                }
            })

            viewModel.presentAvailableBatchRetranscription()
            #expect(await waitUntil { viewModel.pendingBatchTranscriptionConfirmation != nil })
            let confirmation = try #require(viewModel.pendingBatchTranscriptionConfirmation)
            #expect(confirmation.isRetranscription)
            viewModel.pendingBatchTranscriptionConfirmation = nil

            viewModel.cancelFailedBatchRetranscription()
            #expect(await waitUntil { viewModel.batchTranscriptionState == nil })
            #expect(viewModel.canRetranscribeBatchAudio)
        }

        @Test
        func failedSessionWithNonReadyAudioDoesNotOfferRetry() async throws {
            let batch = try BatchAudioTestFixture(
                name: "failed-damaged-audio",
                endedAt: Date(timeIntervalSince1970: 1_776_384_001),
                duration: 1
            )
            defer { batch.removeFiles() }
            try await batch.recordMicrophoneAudio()
            try await markBatchFailed(batch)
            try await batch.database.dbQueue.write { db in
                guard var segment = try RecordingAudioSegmentRecord.fetchOne(db) else {
                    throw CocoaError(.fileNoSuchFile)
                }
                segment.state = .failed
                try segment.update(db)
            }

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
            #expect(!viewModel.canRetranscribeBatchAudio)
        }

        @Test
        func failedMultiSessionRetranscriptionRequiresEveryPendingAudioSession() async throws {
            let completedAt = Date(timeIntervalSince1970: 1_776_384_002)
            let batch = try BatchAudioTestFixture(
                name: "failed-multi-session-retranscription",
                endedAt: Date(timeIntervalSince1970: 1_776_384_001),
                duration: 1,
                retainAudioAfterBatch: true,
                batchCompletedAt: completedAt
            )
            defer { batch.removeFiles() }
            try await batch.recordMicrophoneAudio()

            let unavailableSession = RecordingSessionRecord(
                id: .v7(),
                meetingId: batch.meeting.id,
                startedAt: batch.now.addingTimeInterval(10),
                endedAt: batch.now.addingTimeInterval(11),
                duration: 1,
                offsetSeconds: 10,
                createdAt: batch.now,
                updatedAt: batch.now,
                transcriptionMode: .batch,
                retainAudioAfterBatch: true,
                batchCompletedAt: completedAt
            )
            try await batch.database.dbQueue.write { db in
                guard var availableSession = try RecordingSessionRecord.fetchOne(db, key: batch.session.id) else {
                    throw CocoaError(.fileNoSuchFile)
                }
                availableSession.batchLastAttemptAt = completedAt.addingTimeInterval(1)
                availableSession.batchLastError = "retranscription failed"
                try availableSession.update(db)

                var unavailableSession = unavailableSession
                unavailableSession.batchLastAttemptAt = completedAt.addingTimeInterval(1)
                unavailableSession.batchLastError = "retranscription failed"
                try unavailableSession.insert(db)
            }

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
                if case .retranscriptionFailed = viewModel.batchTranscriptionState { true } else { false }
            })

            #expect(!viewModel.canRetranscribeBatchAudio)
            viewModel.presentAvailableBatchRetranscription()
            #expect(viewModel.pendingBatchTranscriptionConfirmation == nil)
        }

        private func markBatchFailed(_ batch: BatchAudioTestFixture) async throws {
            try await batch.database.dbQueue.write { db in
                guard var session = try RecordingSessionRecord.fetchOne(db, key: batch.session.id) else {
                    throw CocoaError(.fileNoSuchFile)
                }
                session.batchLanguageDetectionMode = .automatic
                session.batchSelectedLocaleIdentifier = nil
                session.batchAutomaticLanguageCandidatesJSON = try BatchLanguageDetectionCandidateSnapshot(
                    scope: .selected,
                    languageIdentifiers: ["en", "ja"]
                ).encoded()
                session.batchLastError = L10n.batchLanguageDetectionFailed
                session.batchLastAttemptAt = batch.now
                session.batchAttemptCount = 1
                try session.update(db)
            }
        }

        private func waitUntil(
            timeout: Duration = testPollTimeout,
            condition: () -> Bool
        ) async -> Bool {
            await pollUntil(timeout: timeout) { condition() }
        }
    }
#endif
