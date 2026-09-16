import Foundation
import GRDB
import Synchronization
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct CaptionViewModelBatchRetryTests {
        @Test
        func startupRecoveryRefreshesOffscreenUnprocessedRecordings() async throws {
            let batch = try BatchAudioTestFixture(
                name: "offscreen-startup-recovery",
                endedAt: Date(timeIntervalSince1970: 1_776_384_001),
                duration: 1
            )
            defer { batch.removeFiles() }
            try await batch.recordMicrophoneAudio()
            try await batch.database.dbQueue.write { db in
                guard var session = try RecordingSessionRecord.fetchOne(db, key: batch.session.id) else {
                    throw CocoaError(.fileNoSuchFile)
                }
                session.batchLastAttemptAt = batch.now
                try session.update(db)
                try db.execute(sql: """
                CREATE TRIGGER fail_startup_batch_recovery
                BEFORE UPDATE OF batchLastError ON recording_sessions
                BEGIN
                    SELECT RAISE(ABORT, 'forced startup recovery failure');
                END
                """)
            }
            var recoveredState: BackupPreflightItem.State?
            let viewModel = CaptionViewModel()

            viewModel.configureBatchTranscription(
                dbQueue: batch.database.dbQueue,
                managedRootURL: batch.managedRootURL
            ) {
                recoveredState = try? await BackupService(dbQueue: batch.database.dbQueue)
                    .preflightItems(workspaceId: batch.meeting.workspaceId)
                    .first?
                    .state
            }

            #expect(await waitUntil { viewModel.batchTranscriptionRecoveryAlert != nil })
            #expect(recoveredState == nil)
            try await batch.database.dbQueue.write { db in
                try db.execute(sql: "DROP TRIGGER fail_startup_batch_recovery")
            }

            viewModel.retryBatchTranscriptionRecovery()

            #expect(await waitUntil { recoveredState == .interrupted })
            #expect(viewModel.batchTranscriptionRecoveryAlert == nil)
        }

        @Test
        func retainedCompletedAudioOffersRetranscription() async throws {
            let batch = try BatchAudioTestFixture(
                name: "retained-completed-audio",
                endedAt: Date(timeIntervalSince1970: 1_776_384_001),
                duration: 1,
                batchCompletedAt: .now
            )
            defer { batch.removeFiles() }
            try await batch.recordMicrophoneAudio()
            let retention = BatchTranscriptionCoordinator(
                dbQueue: batch.database.dbQueue,
                managedRootURL: batch.managedRootURL,
                audioRetentionPeriod: .oneDay
            ) { _ in }
            await retention.refreshExpiredAudio()

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
                workspaceURL: batch.workspaceURL
            )
            #expect(await waitUntil { viewModel.canRetranscribeBatchAudio })

            viewModel.presentBatchRetranscriptionConfirmation()

            let confirmation = try #require(viewModel.pendingBatchTranscriptionConfirmation)
            #expect(confirmation.isRetranscription)
            #expect(confirmation.sessionId == batch.session.id)
            guard case let .retranscription(sessionIds) = confirmation.purpose else {
                Issue.record("Expected a retranscription confirmation")
                return
            }
            #expect(sessionIds == [batch.session.id])
        }

        @Test
        func newConfirmationDefaultsToManualSelectedLanguage() {
            let summaryOptions = SummaryGenerationOptions(
                exportOptions: .manual,
                detailLevel: .eventSession
            )
            let confirmation = BatchTranscriptionConfirmation(
                sessionId: .v7(),
                meetingId: .v7(),
                suggestedLocaleIdentifier: "ja_JP",
                summaryGenerationOptions: summaryOptions
            )

            #expect(confirmation.initialLanguageSelection == .manual(localeIdentifier: "ja_JP"))
            #expect(!confirmation.allowsRecordedLanguageSelection)
            #expect(confirmation.summaryGenerationOptions == summaryOptions)

            let retry = BatchTranscriptionConfirmation(
                sessionId: confirmation.sessionId,
                meetingId: confirmation.meetingId,
                suggestedLocaleIdentifier: "ja_JP",
                initialLanguageSelection: .automatic,
                allowsRecordedLanguageSelection: true,
                summaryGenerationOptions: confirmation.summaryGenerationOptions
            )
            #expect(retry.allowsRecordedLanguageSelection)
            #expect(retry.summaryGenerationOptions.detailLevel == .eventSession)
        }

        @Test
        func failedConfirmationKeepsDisabledSummaryDetailSelection() async throws {
            let batch = try BatchAudioTestFixture(
                name: "failed-confirmation-summary-detail",
                endedAt: Date(timeIntervalSince1970: 1_776_384_001),
                duration: 1
            )
            defer { batch.removeFiles() }
            try await batch.recordMicrophoneAudio()
            try await batch.database.dbQueue.write { db in
                try db.execute(sql: """
                CREATE TRIGGER fail_batch_confirmation
                BEFORE UPDATE OF batchLastAttemptAt ON recording_sessions
                BEGIN
                    SELECT RAISE(ABORT, 'forced confirmation failure');
                END
                """)
            }
            let viewModel = CaptionViewModel()
            viewModel.configureBatchTranscription(
                dbQueue: batch.database.dbQueue,
                managedRootURL: batch.managedRootURL,
                recoverExistingSessions: false
            )
            await viewModel.presentManualBatchTranscription(
                sessionId: batch.session.id,
                meetingId: batch.meeting.id,
                dbQueue: batch.database.dbQueue
            )

            let selectedOptions = SummaryGenerationOptions(
                exportOptions: .manual,
                detailLevel: .eventSession
            )
            viewModel.confirmBatchTranscription(
                languageSelection: .manual(localeIdentifier: "ja_JP"),
                generatesSummary: false,
                summaryGenerationOptions: selectedOptions
            )

            #expect(await waitUntil {
                guard let confirmation = viewModel.pendingBatchTranscriptionConfirmation else { return false }
                return !confirmation.initiallyGeneratesSummary
                    && confirmation.summaryGenerationOptions == selectedOptions
            })
        }

        @Test
        func manualBatchTranscriptionCannotStartWhileRecording() async throws {
            let batch = try BatchAudioTestFixture(
                name: "manual-batch-during-recording",
                endedAt: Date(timeIntervalSince1970: 1_776_384_001),
                duration: 1
            )
            defer { batch.removeFiles() }
            try await batch.recordMicrophoneAudio()
            let viewModel = CaptionViewModel()
            viewModel.configureBatchTranscription(
                dbQueue: batch.database.dbQueue,
                managedRootURL: batch.managedRootURL,
                recoverExistingSessions: false
            )

            viewModel.isListening = true
            await viewModel.presentManualBatchTranscription(
                sessionId: batch.session.id,
                meetingId: batch.meeting.id,
                dbQueue: batch.database.dbQueue
            )
            #expect(viewModel.pendingBatchTranscriptionConfirmation == nil)

            viewModel.isListening = false
            await viewModel.presentManualBatchTranscription(
                sessionId: batch.session.id,
                meetingId: batch.meeting.id,
                dbQueue: batch.database.dbQueue
            )
            #expect(viewModel.pendingBatchTranscriptionConfirmation != nil)

            viewModel.isListening = true
            viewModel.confirmBatchTranscription(
                languageSelection: .manual(localeIdentifier: "ja_JP"),
                generatesSummary: false,
                summaryGenerationOptions: .manual
            )
            #expect(viewModel.pendingBatchTranscriptionConfirmation != nil)
            let session = try await batch.database.dbQueue.read { db in
                try #require(try RecordingSessionRecord.fetchOne(db, key: batch.session.id))
            }
            #expect(session.batchLastAttemptAt == nil)
        }

        @Test
        func failedAutomaticBatchRetryPresentsLanguageSelection() async throws {
            let batch = try BatchAudioTestFixture(
                name: "failed-auto-retry-selection",
                endedAt: Date(timeIntervalSince1970: 1_776_384_001),
                duration: 1
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
                workspaceURL: batch.workspaceURL
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
            #expect(confirmation.automaticLanguageCandidateSnapshot?.identifierSet == ["en", "ja"])
        }

        @Test
        func discardedFailedBatchNoLongerOffersRetranscription() async throws {
            let batch = try BatchAudioTestFixture(
                name: "discarded-failed-retry",
                endedAt: Date(timeIntervalSince1970: 1_776_384_001),
                duration: 1
            )
            defer { batch.removeFiles() }
            try await batch.recordMicrophoneAudio()
            try await markBatchFailed(batch)

            let viewModel = CaptionViewModel()
            viewModel.loadMeeting(
                batch.meeting.id,
                dbQueue: batch.database.dbQueue,
                projectURL: nil,
                projectId: nil,
                workspaceURL: batch.workspaceURL
            )
            #expect(await waitUntil { viewModel.canRetranscribeBatchAudio })

            viewModel.discardFailedBatchTranscription()

            #expect(await waitUntil { viewModel.batchTranscriptionState == nil })
            #expect(viewModel.retranscribableBatchSessionIds.isEmpty)
            #expect(!viewModel.canRetranscribeBatchAudio)
        }

        @Test
        func failedRetranscriptionOffersRetryAndCanKeepCurrentTranscript() async throws {
            let completedAt = Date(timeIntervalSince1970: 1_776_384_002)
            let batch = try BatchAudioTestFixture(
                name: "failed-retranscription",
                endedAt: Date(timeIntervalSince1970: 1_776_384_001),
                duration: 1,
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
                workspaceURL: batch.workspaceURL
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
        func interruptedRetranscriptionOffersResumeConfirmation() async throws {
            let completedAt = Date(timeIntervalSince1970: 1_776_384_002)
            let batch = try BatchAudioTestFixture(
                name: "interrupted-retranscription",
                endedAt: Date(timeIntervalSince1970: 1_776_384_001),
                duration: 1,
                batchCompletedAt: completedAt
            )
            defer { batch.removeFiles() }
            try await batch.recordMicrophoneAudio()
            try await batch.database.dbQueue.write { db in
                guard var session = try RecordingSessionRecord.fetchOne(db, key: batch.session.id) else {
                    throw CocoaError(.fileNoSuchFile)
                }
                session.batchLastAttemptAt = completedAt.addingTimeInterval(1)
                session.batchLastError = L10n.batchTranscriptionInterrupted
                session.batchFailureKind = .transcriptionInterrupted
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
                workspaceURL: batch.workspaceURL
            )
            #expect(await waitUntil {
                viewModel.batchTranscriptionState == .interrupted(
                    sessionId: batch.session.id,
                    isRetranscription: true
                ) && viewModel.canRetranscribeBatchAudio
            })

            viewModel.presentAvailableBatchRetranscription()

            #expect(await waitUntil { viewModel.pendingBatchTranscriptionConfirmation != nil })
            let confirmation = try #require(viewModel.pendingBatchTranscriptionConfirmation)
            #expect(confirmation.isRetranscription)
            #expect(confirmation.sessionId == batch.session.id)
            viewModel.pendingBatchTranscriptionConfirmation = nil

            viewModel.cancelFailedBatchRetranscription()

            #expect(await waitUntil { viewModel.batchTranscriptionState == nil })
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
                workspaceURL: batch.workspaceURL
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
                workspaceURL: batch.workspaceURL
            )
            #expect(await waitUntil {
                if case .retranscriptionFailed = viewModel.batchTranscriptionState { true } else { false }
            })

            #expect(!viewModel.canRetranscribeBatchAudio)
            viewModel.presentAvailableBatchRetranscription()
            #expect(viewModel.pendingBatchTranscriptionConfirmation == nil)
        }

        @Test
        func serverRetranscriptionRetriesCapabilityCheckAndWaitsForEveryArchive() async throws {
            let completedAt = Date(timeIntervalSince1970: 1_776_384_002)
            let batch = try BatchAudioTestFixture(
                name: "server-retranscription-availability",
                endedAt: Date(timeIntervalSince1970: 1_776_384_001),
                duration: 1,
                batchCompletedAt: completedAt
            )
            defer { batch.removeFiles() }
            let connectionID = UUID.v7()
            let replacementConnectionID = UUID.v7()
            let secondSessionID = UUID.v7()
            let origin = "https://retranscription-\(connectionID.uuidString.lowercased()).test"
            let replacementOrigin = "https://retranscription-\(replacementConnectionID.uuidString.lowercased()).test"
            let audioJSON = try String(decoding: SyncJSON.encoder.encode([
                "mic": RecordingArchivedAudio(
                    contentType: "audio/mp4",
                    size: 1,
                    checksum: "SHA-256:" + String(repeating: "0", count: 64),
                    contentURL: "/audio",
                    manifest: .init(sampleRate: 16_000, frameCount: 16_000, ranges: [])
                ),
            ]), as: UTF8.self)
            try await batch.database.dbQueue.write { db in
                try DahliaAccountConnectionRecord(
                    id: connectionID,
                    origin: origin,
                    clientID: "test",
                    createdAt: .now
                ).insert(db)
                try DahliaAccountConnectionRecord(
                    id: replacementConnectionID,
                    origin: replacementOrigin,
                    clientID: "test",
                    createdAt: .now
                ).insert(db)
                var workspace = try #require(try WorkspaceRecord.fetchOne(db, key: batch.meeting.workspaceId))
                workspace.accountConnectionId = connectionID
                workspace.organizationId = .v7()
                workspace.syncRole = "admin"
                workspace.syncConfirmedConnectionId = connectionID
                workspace.syncPullCursor = "ready"
                try workspace.update(db)
                try RecordingSessionRecord(
                    id: secondSessionID,
                    meetingId: batch.meeting.id,
                    startedAt: batch.now.addingTimeInterval(10),
                    endedAt: batch.now.addingTimeInterval(11),
                    duration: 1,
                    offsetSeconds: 10,
                    createdAt: batch.now,
                    updatedAt: batch.now,
                    transcriptionMode: .batch,
                    batchCompletedAt: completedAt
                ).insert(db)
                try RecordingArchiveRecord(
                    sessionId: batch.session.id,
                    meetingId: batch.meeting.id,
                    workspaceId: batch.meeting.workspaceId,
                    connectionId: connectionID,
                    number: 1,
                    audioJSON: audioJSON,
                    state: "remote"
                ).insert(db)
                try RecordingArchiveRecord(
                    sessionId: secondSessionID,
                    meetingId: batch.meeting.id,
                    workspaceId: batch.meeting.workspaceId,
                    connectionId: connectionID
                ).insert(db)
            }
            let requests = Mutex(0)
            ImageURLProtocol.register(origin: origin) { _ in
                let number = requests.withLock { value in
                    value += 1
                    return value
                }
                if number == 1 { return (503, [:], Data()) }
                return (200, [:], Data(
                    #"{"meetingSummaryGeneration":{"version":2,"sources":["audio"],"completeRecordings":true,"retranscription":{"version":1,"provider":"gemini"}}}"#.utf8
                ))
            }
            defer { ImageURLProtocol.remove(origin: origin) }
            let replacementRequests = Mutex(0)
            ImageURLProtocol.register(origin: replacementOrigin) { _ in
                replacementRequests.withLock { $0 += 1 }
                return (200, [:], Data(
                    #"{"meetingSummaryGeneration":{"version":2,"sources":["audio"],"completeRecordings":true}}"#.utf8
                ))
            }
            defer { ImageURLProtocol.remove(origin: replacementOrigin) }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ImageURLProtocol.self]
            let viewModel = CaptionViewModel(serverSummaryService: ServerSummaryService(client: SyncAPIClient(
                session: URLSession(configuration: configuration),
                tokenProvider: { _, _ in "test" }
            )))
            viewModel.loadMeeting(
                batch.meeting.id,
                dbQueue: batch.database.dbQueue,
                projectURL: nil,
                projectId: nil,
                workspaceURL: batch.workspaceURL
            )

            #expect(await waitUntil { viewModel.canRetryServerRetranscriptionAvailability })
            #expect(viewModel.retranscribableBatchSessionIds.isEmpty)

            viewModel.retryServerRetranscriptionAvailability()
            #expect(viewModel.isCheckingServerRetranscriptionAvailability)
            #expect(viewModel.serverRetranscriptionUnavailableReason == nil)
            #expect(!viewModel.canRetranscribeBatchAudio)
            #expect(await waitUntil {
                !viewModel.isCheckingServerRetranscriptionAvailability
                    && viewModel.serverRetranscriptionUnavailableReason == nil
                    && requests.withLock { $0 } >= 2
            })
            #expect(viewModel.retranscribableBatchSessionIds.isEmpty)

            try await batch.database.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE recording_archives SET number = 2, audioJSON = ?, state = 'remote' WHERE sessionId = ?",
                    arguments: [audioJSON, secondSessionID]
                )
            }
            #expect(await waitUntil {
                viewModel.recordingArchiveState == "saved"
                    && viewModel.retranscribableBatchSessionIds == [batch.session.id, secondSessionID]
                    && viewModel.canRetranscribeBatchAudio
            })

            try await batch.database.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE recording_archives SET connectionId = ? WHERE meetingId = ?",
                    arguments: [replacementConnectionID, batch.meeting.id]
                )
                try db.execute(
                    sql: "UPDATE workspaces SET accountConnectionId = ?, syncConfirmedConnectionId = ? WHERE id = ?",
                    arguments: [replacementConnectionID, replacementConnectionID, batch.meeting.workspaceId]
                )
            }
            #expect(await waitUntil {
                replacementRequests.withLock { $0 } > 0
                    && viewModel.serverRetranscriptionUnavailableReason == L10n.serverRetranscriptionUnsupported
                    && !viewModel.canRetranscribeBatchAudio
            })

            try await batch.database.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE recording_sessions SET batchCompletedAt = NULL, batchLastAttemptAt = ?, batchLastError = ? WHERE id = ?",
                    arguments: [Date.now, "initial transcription failed", secondSessionID]
                )
            }
            viewModel.loadMeeting(
                batch.meeting.id,
                dbQueue: batch.database.dbQueue,
                projectURL: nil,
                projectId: nil,
                workspaceURL: batch.workspaceURL
            )
            #expect(await waitUntil {
                if case .failed = viewModel.batchTranscriptionState {
                    viewModel.canStartOrResumeBatchTranscription
                } else {
                    false
                }
            })

            viewModel.presentAvailableBatchRetranscription()
            #expect(viewModel.pendingBatchTranscriptionConfirmation?.isRetranscription == false)
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
