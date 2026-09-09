#if canImport(Testing)
    import DahliaMeetingAccess
    import DahliaRuntimeSupport
    import Foundation
    import GRDB
    import Testing
    @testable import Dahlia

    @MainActor
    struct RecordingProcessingTests {
        @Test
        func legacyTranscriptServerSettingsRemainServerRoutedAfterReload() throws {
            let settings = try JSONDecoder().decode(ServerAccountSettings.self, from: Data("""
            {"summary":{"method":"transcript","detail":"high","methodSettings":{"transcript":{"model":"saved","reasoningEffort":"high"}}},
             "outputLanguage":"ja","analysisLanguages":{"scope":"all","identifiers":[]}}
            """.utf8))
            let processing = Self.processing(serverSettings: settings)
            let restored = try JSONDecoder().decode(RecordingProcessing.self, from: JSONEncoder().encode(processing))
            #expect(restored.usesServerSummary == true)
            #expect(restored.serverSettings?.summary?.legacyMethod == "transcript")
        }

        @Test(arguments: [String?.none, "pending", "processing", "succeeded", "failed", "cancelled"])
        func serverRetryPreservesIdentityUnlessTheAttemptIsTerminal(status: String?) throws {
            var processing = Self.processing(method: .cloudTranscription)
            let originalID = processing.id
            processing.stage = .failed
            processing.error = "Network interrupted"
            processing.serverRequest = .init(
                id: originalID.uuidString.lowercased(), input: .init(type: "recording", recordings: []),
                model: "gemini", detailLevel: "max", summaryLanguage: "ja", reasoningEffort: "high"
            )
            let job = status.map { ServerSummaryService.Job(id: originalID.uuidString.lowercased(), status: $0, error: nil, stage: nil) }
            #expect(job?.isTerminal == status.map { ["failed", "cancelled", "succeeded"].contains($0) })
            processing.prepareRetry(serverJob: job)
            let restored = try JSONDecoder().decode(RecordingProcessing.self, from: JSONEncoder().encode(processing))
            #expect((restored.id != originalID) == (job?.isRetryable == true))
            #expect(restored.serverRequest?.id == restored.id.uuidString.lowercased())
            #expect(restored.retryOf == (job?.isRetryable == true ? job?.id : nil))
            #expect(restored.stage == .uploading)
            #expect(restored.error == nil)
            #expect(restored.serverRequest?.summaryLanguage == "ja")
            #expect(restored.serverRequest?.reasoningEffort == "high")
        }

        @Test(arguments: [false, true])
        func priorCancellationAllowsNewWorkButNewCancellationRejectsInFlightWork(cancelDuringWork: Bool) async throws {
            let fixture = try BatchAudioTestFixture(name: "PriorCancellation", endedAt: .now)
            defer { fixture.removeFiles() }
            let priorID = UUID.v7()
            var prior = Self.processing()
            prior.stage = cancelDuringWork ? .transcribing : .cancelled
            let initial = prior
            try await fixture.database.dbQueue.write { db in
                var session = fixture.session
                session.id = priorID
                try session.insert(db)
                try initial.save(sessionID: priorID, in: db)
            }
            let expected = try await fixture.database.dbQueue.read { db in try RecordingSessionRecord.fetchAll(db) }
            prior.stage = .cancelled
            let cancelled = prior
            try await fixture.database.dbQueue.write { db in try cancelled.save(sessionID: priorID, in: db) }
            let complete = {
                try BatchTranscriptionPersistence.complete(
                    sessionId: fixture.session.id, meetingId: fixture.meeting.id, records: [], completedAt: .now,
                    dbQueue: fixture.database.dbQueue, replacingMeeting: true, expectedSessions: expected
                )
            }
            if cancelDuringWork { #expect(throws: CancellationError.self) { try complete() } } else { try complete() }
        }

        @Test
        func migrationPreservesExistingRecording() throws {
            let queue = try DatabaseQueue(configuration: AppDatabaseManager.configuration())
            try AppDatabaseManager.migrator.migrate(queue, upTo: "v41_vaultAISettingsBackfill")
            let vaultID = UUID.v7(), meetingID = UUID.v7(), sessionID = UUID.v7()
            try queue.write { db in
                try db.execute(
                    sql: "INSERT INTO vaults(id, path, name, createdAt, lastOpenedAt) VALUES (?, '/tmp/existing', 'Existing', ?, ?)",
                    arguments: [vaultID, Date.now, Date.now]
                )
                try MeetingRecord(id: meetingID, vaultId: vaultID, projectId: nil, name: "Existing", createdAt: .now, updatedAt: .now).insert(db)
                try db.execute(sql: """
                INSERT INTO recording_sessions(id, meetingId, startedAt, endedAt, offsetSeconds, createdAt, updatedAt, transcriptionMode,
                    batchLastError, batchAttemptCount) VALUES (?, ?, ?, ?, 0, ?, ?, 'batch', 'interrupted', 2)
                """, arguments: [sessionID, meetingID, Date.now, Date.now, Date.now, Date.now])
            }
            try AppDatabaseManager.migrator.migrate(queue)
            try queue.read { db in
                let session = try #require(try RecordingSessionRecord.fetchOne(db, key: sessionID))
                #expect(session.meetingId == meetingID)
                #expect(session.batchLastError == "interrupted")
                #expect(session.batchAttemptCount == 2)
                #expect(session.processingJSON == nil)
                #expect(try MeetingRecord.fetchOne(db, key: meetingID)?.name == "Existing")
                #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
            }
        }

        @Test(arguments: RecordingProcessingMethod.allCases, [false, true])
        func settingsAndStageSurviveReload(method: RecordingProcessingMethod, automatic: Bool) throws {
            let fixture = try BatchAudioTestFixture(name: "ProcessingSnapshot", endedAt: .now)
            defer { fixture.removeFiles() }
            var processing = Self.processing(method: method, automatic: automatic)
            processing.stage = .generating
            processing.sessionIDs = [fixture.session.id]
            try fixture.database.dbQueue.write { db in try processing.save(sessionID: fixture.session.id, in: db) }
            let saved = try #require(fixture.database.dbQueue.read { db in try RecordingProcessing.load(sessionID: fixture.session.id, in: db) })
            #expect(saved.id == processing.id)
            #expect(saved.method == method)
            #expect(saved.automatic == automatic)
            #expect(saved.stage == .generating)
            #expect(saved.generationSettings == processing.generationSettings)
            #expect(saved.options.detailLevel == .max)
        }

        @Test
        func cancellationRejectsDelayedTranscriptAndSummaryWithoutDeletingAudioOrOldText() async throws {
            let fixture = try BatchAudioTestFixture(name: "ProcessingCancellation", endedAt: .now)
            defer { fixture.removeFiles() }
            try await fixture.recordMicrophoneAudio()
            let prior = TranscriptInfo(id: .v7(), startedAt: fixture.now, endedAt: .now, metadata: nil)
            var processing = Self.processing()
            processing.stage = .cancelled
            let cancelled = processing
            try await fixture.database.dbQueue.write { db in
                try cancelled.save(sessionID: fixture.session.id, in: db)
                try TranscriptRecord(meetingId: fixture.meeting.id, info: prior).insert(db)
                try TranscriptContent(
                    from: TranscriptSegment(startTime: fixture.now, text: "retained first draft", isConfirmed: true),
                    meetingId: fixture.meeting.id,
                    defaultSessionId: fixture.session.id
                ).insert(db)
            }
            #expect(throws: CancellationError.self) {
                try BatchTranscriptionPersistence.complete(
                    sessionId: fixture.session.id,
                    meetingId: fixture.meeting.id,
                    records: [],
                    completedAt: .now,
                    dbQueue: fixture.database.dbQueue
                )
            }
            let expected = SummaryGenerationExpectation(
                summaryDocument: nil,
                transcriptID: prior.id,
                recordingSessionID: fixture.session.id,
                jobID: processing.id
            )
            #expect(throws: CancellationError.self) {
                try fixture.database.dbQueue.read { db in try expected.validate(meetingID: fixture.meeting.id, in: db) }
            }
            try await fixture.database.dbQueue.read { db in
                let texts = try TranscriptSegmentBodyRecord.fetchAll(db).map(\.text)
                let audioCount = try RecordingAudioSegmentRecord.filter(Column("recordingSessionId") == fixture.session.id).fetchCount(db)
                let session = try RecordingSessionRecord.fetchOne(db, key: fixture.session.id)
                #expect(texts == ["retained first draft"])
                #expect(audioCount > 0)
                #expect(session?.batchDiscardedAt == nil)
            }
        }

        @Test
        func summarySaveRejectsEditsAndCommitsItsProcessingCheckpointAtomically() throws {
            let fixture = try BatchAudioTestFixture(name: "ProcessingSummary", endedAt: .now)
            defer { fixture.removeFiles() }
            let processing = Self.processing()
            try fixture.database.dbQueue.write { db in try processing.save(sessionID: fixture.session.id, in: db) }
            let expected = SummaryGenerationExpectation(
                summaryDocument: nil,
                transcriptID: nil,
                recordingSessionID: fixture.session.id,
                jobID: processing.id
            )
            let repository = MeetingRepository(dbQueue: fixture.database.dbQueue)
            try repository.applyGeneratedSummary(
                toMeetingId: fixture.meeting.id,
                document: SummaryDocument(title: "Saved", sections: []),
                tags: [],
                expectation: expected
            )
            #expect(try fixture.database.dbQueue.read { db in
                try RecordingProcessing.load(sessionID: fixture.session.id, in: db)?.stage
            } == .saving)
            #expect(throws: TextContentError.changed) {
                try repository.applyGeneratedSummary(
                    toMeetingId: fixture.meeting.id,
                    document: SummaryDocument(title: "Late", sections: []),
                    tags: [],
                    expectation: expected
                )
            }
            #expect(try fixture.database.dbQueue.read { db in
                try SummaryBodyRecord.fetchOne(db, key: fixture.meeting.id)?.document.contains("Saved")
            } == true)
        }

        @Test(arguments: RecordingProcessingMethod.allCases, [false, true])
        func retranscriptionSupersedesPreviousProcessingAndHonorsOptionalSummary(
            method: RecordingProcessingMethod,
            generatesSummary: Bool
        ) async throws {
            let fixture = try BatchAudioTestFixture(name: "FreshRetranscription", endedAt: .now, batchCompletedAt: .now)
            defer { fixture.removeFiles() }
            try await fixture.recordMicrophoneAudio()
            var old = Self.processing(method: method)
            old.stage = .cancelled
            let previous = old
            try await fixture.database.dbQueue.write { db in try previous.save(sessionID: fixture.session.id, in: db) }
            let staleSessions = try await fixture.database.dbQueue.read { db in try RecordingSessionRecord.fetchAll(db) }
            var fresh = Self.processing()
            fresh.stage = .transcribing
            _ = try await BatchTranscriptionConfirmationService.confirmRetranscription(
                sessionIds: [fixture.session.id], processing: generatesSummary ? fresh : nil,
                processingSessionID: fixture.session.id, languageSelection: .manual(localeIdentifier: "en_US"),
                automaticLanguageCandidates: nil, dbQueue: fixture.database.dbQueue
            )
            let saved = try await fixture.database.dbQueue.read { db in try RecordingProcessing.load(sessionID: fixture.session.id, in: db) }
            #expect(saved?.id == (generatesSummary ? fresh.id : nil))
            #expect(saved?.serverRequest == nil)
            #expect(saved?.summaryExpectation == nil)
            #expect(saved?.generatedSummary == nil)
            #expect(throws: CancellationError.self) {
                try BatchTranscriptionPersistence.complete(
                    sessionId: fixture.session.id, meetingId: fixture.meeting.id, records: [], completedAt: .now,
                    dbQueue: fixture.database.dbQueue, expectedSessions: staleSessions
                )
            }
            let current = try await fixture.database.dbQueue.read { db in try RecordingSessionRecord.fetchAll(db) }
            try BatchTranscriptionPersistence.complete(
                sessionId: fixture.session.id, meetingId: fixture.meeting.id, records: [], completedAt: .now,
                dbQueue: fixture.database.dbQueue, replacingMeeting: true, expectedSessions: current
            )
            #expect(try await fixture.database.dbQueue.read { db in
                try RecordingSessionRecord.fetchOne(db, key: fixture.session.id)?.isBatchRetranscriptionPending
            } == false)
            _ = try await BatchTranscriptionConfirmationService.confirmRetranscription(
                sessionIds: [fixture.session.id], processing: generatesSummary ? fresh : nil,
                processingSessionID: fixture.session.id, languageSelection: .manual(localeIdentifier: "en_US"),
                automaticLanguageCandidates: nil, dbQueue: fixture.database.dbQueue
            )
            _ = try await BatchTranscriptionConfirmationService.cancelRetranscription(
                sessionIds: [fixture.session.id], dbQueue: fixture.database.dbQueue
            )
            #expect(try await fixture.database.dbQueue.read { db in
                try RecordingProcessing.load(sessionID: fixture.session.id, in: db)
            } == nil)
        }

        @Test
        func retryIdentityRejectsThePreviousTranscriptionWithoutRejectingStageUpdates() async throws {
            let fixture = try BatchAudioTestFixture(name: "RetryIdentity", endedAt: .now)
            defer { fixture.removeFiles() }
            let original = Self.processing()
            try await fixture.database.dbQueue.write { db in try original.save(sessionID: fixture.session.id, in: db) }
            let stale = try await fixture.database.dbQueue.read { db in try RecordingSessionRecord.fetchAll(db) }
            var retry = original
            retry.id = .v7()
            let accepted = retry
            try await fixture.database.dbQueue.write { db in try accepted.save(sessionID: fixture.session.id, in: db) }
            #expect(throws: CancellationError.self) {
                try BatchTranscriptionPersistence.complete(
                    sessionId: fixture.session.id, meetingId: fixture.meeting.id, records: [], completedAt: .now,
                    dbQueue: fixture.database.dbQueue, expectedSessions: stale
                )
            }
            let current = try await fixture.database.dbQueue.read { db in try RecordingSessionRecord.fetchAll(db) }
            retry.stage = .transcribing
            let running = retry
            try await fixture.database.dbQueue.write { db in try running.save(sessionID: fixture.session.id, in: db) }
            try BatchTranscriptionPersistence.complete(
                sessionId: fixture.session.id, meetingId: fixture.meeting.id, records: [], completedAt: .now,
                dbQueue: fixture.database.dbQueue, expectedSessions: current
            )
        }

        private static func processing(
            method: RecordingProcessingMethod = .transcript,
            automatic: Bool = true,
            serverSettings: ServerAccountSettings? = nil
        ) -> RecordingProcessing {
            .init(
                id: .v7(),
                automatic: automatic,
                liveDraft: false,
                localeIdentifier: "ja_JP",
                method: method,
                options: .init(exportOptions: .manual, detailLevel: .max),
                generationSettings: .init(
                    modelID: "saved-model",
                    reasoningEffort: "low",
                    detailLevelInstruction: SummaryDetailLevel.max.instruction,
                    languageDisplayName: "English",
                    runtimeProvider: .chatGPTSubscription
                ),
                serverSettings: serverSettings
            )
        }
    }
#endif
