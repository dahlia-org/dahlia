import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct BatchTranscriptionLocaleConfirmationTests {
        @Test
        func confirmationRestoresAutomaticSelectionFromLegacyWorkspaceSettings() async throws {
            let batch = try BatchAudioTestFixture(name: "legacy-language-selection", endedAt: .now, duration: 1)
            defer { batch.removeFiles() }
            try await batch.recordMicrophoneAudio(localeIdentifier: "ja_JP")
            let workspace = try await batch.database.dbQueue.read { db in
                try #require(try WorkspaceRecord.fetchOne(db, key: batch.meeting.workspaceId))
            }
            let viewModel = CaptionViewModel()
            viewModel.supportedLocales = [Locale(identifier: "en_US"), Locale(identifier: "fr_FR"), Locale(identifier: "ja_JP")]
            let processing = viewModel.processingSnapshot(
                workspace: workspace,
                plan: .init(finalMode: .batch, liveSubtitlesEnabled: false, liveTranscriptDraftEnabled: false),
                locale: Locale(identifier: "ja_JP")
            )
            var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(processing)) as? [String: Any])
            var workspaceSettings = try #require(json["workspaceSettings"] as? [String: Any])
            workspaceSettings["transcription"] = [
                "localeIdentifier": "fr_FR",
                "automaticLanguageDetection": true,
                "languageScope": "selected",
                "languageIdentifiers": ["en", "fr"],
                "liveTranscriptDraft": true,
            ]
            json["workspaceSettings"] = workspaceSettings
            json.removeValue(forKey: "automaticLanguageDetection")
            json.removeValue(forKey: "automaticLanguageCandidates")
            let processingJSON = String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self)
            try await batch.database.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE recording_sessions SET processingJSON = ? WHERE id = ?",
                    arguments: [processingJSON, batch.session.id]
                )
            }

            await viewModel.presentBatchTranscriptionConfirmation(
                sessionId: batch.session.id, meetingId: batch.meeting.id, dbQueue: batch.database.dbQueue
            )

            let confirmation = try #require(viewModel.pendingBatchTranscriptionConfirmation)
            #expect(confirmation.initialLanguageSelection == .automatic)
            #expect(confirmation.automaticLanguageCandidateSnapshot?.identifierSet == ["en", "fr"])
        }

        @Test(arguments: [false, true])
        func confirmationPreservesStoredLocale(retry: Bool) async throws {
            let settings = AppSettings.shared
            let previous = (settings.appLanguageScope, settings.enabledLanguageIdentifiers)
            defer {
                settings.appLanguageScope = previous.0
                settings.enabledLanguageIdentifiers = previous.1
            }
            settings.appLanguageScope = .selected
            settings.enabledLanguageIdentifiers = ["en", "ja"]
            let batch = try BatchAudioTestFixture(name: "stored-recording-locale", endedAt: .now, duration: 1)
            defer { batch.removeFiles() }
            try await batch.recordMicrophoneAudio(localeIdentifier: "en_US")
            try await batch.database.dbQueue.write { db in
                if retry {
                    var session = batch.session
                    session.batchSelectedLocaleIdentifier = "en_US"
                    session.batchLastError = "Retry required"
                    session.batchAttemptCount = 1
                    try session.update(db)
                }
            }
            let viewModel = CaptionViewModel()
            viewModel.supportedLocales = [Locale(identifier: "en_US"), Locale(identifier: "ja_JP")]
            await viewModel.presentBatchTranscriptionConfirmation(
                sessionId: batch.session.id, meetingId: batch.meeting.id, dbQueue: batch.database.dbQueue
            )
            let confirmation = try #require(viewModel.pendingBatchTranscriptionConfirmation)
            #expect(confirmation.initialLanguageSelection == .manual(localeIdentifier: "en_US"))
            #expect(confirmation.automaticLanguageCandidateSnapshot?.identifierSet == ["en", "ja"])
            _ = try await BatchTranscriptionConfirmationService.confirm(
                sessionId: batch.session.id,
                languageSelection: confirmation.initialLanguageSelection,
                automaticLanguageCandidates: confirmation.automaticLanguageCandidateSnapshot,
                dbQueue: batch.database.dbQueue
            )
            let locales = try await batch.database.dbQueue.read { db in
                try RecordingAudioSegmentRangeRecord.fetchAll(db).map(\.localeIdentifier)
            }
            #expect(locales == ["en_US"])
        }

        @Test(arguments: [false, true])
        func confirmationPreservesLocalesChangedWhileRecording(capturesProcessing: Bool) async throws {
            let batch = try BatchAudioTestFixture(
                name: "recording-locale-ranges",
                endedAt: Date(timeIntervalSince1970: 1_776_384_001),
                duration: 1
            )
            defer { batch.removeFiles() }
            let viewModel = CaptionViewModel()
            if capturesProcessing {
                let workspace = try await batch.database.dbQueue.read { db in
                    try #require(try WorkspaceRecord.fetchOne(db, key: batch.meeting.workspaceId))
                }
                let processing = viewModel.processingSnapshot(
                    workspace: workspace,
                    plan: .init(finalMode: .batch, liveSubtitlesEnabled: false, liveTranscriptDraftEnabled: false),
                    locale: Locale(identifier: "ja_JP")
                )
                try await batch.database.dbQueue.write { db in
                    try processing.saveForRecordingStart(sessionID: batch.session.id, in: db)
                }
            }
            try await batch.recordMicrophoneAudio()
            try await batch.database.dbQueue.write { db in
                let fetchedRange = try RecordingAudioSegmentRangeRecord.fetchOne(db)
                let firstRange = try #require(fetchedRange)
                var closedFirstRange = firstRange
                closedFirstRange.frameCount = 1
                try closedFirstRange.update(db)
                try RecordingAudioSegmentRangeRecord(
                    id: .v7(),
                    audioSegmentId: firstRange.audioSegmentId,
                    startFrame: 1,
                    frameCount: nil,
                    sessionOffsetSeconds: firstRange.sessionOffsetSeconds,
                    localeIdentifier: "en_US",
                    createdAt: batch.now,
                    updatedAt: batch.now
                ).insert(db)
            }

            await viewModel.presentBatchTranscriptionConfirmation(
                sessionId: batch.session.id,
                meetingId: batch.meeting.id,
                dbQueue: batch.database.dbQueue
            )

            let confirmation = try #require(viewModel.pendingBatchTranscriptionConfirmation)
            #expect(confirmation.initialLanguageSelection == .recorded)
            _ = try await BatchTranscriptionConfirmationService.confirm(
                sessionId: batch.session.id,
                languageSelection: confirmation.initialLanguageSelection,
                automaticLanguageCandidates: confirmation.automaticLanguageCandidateSnapshot,
                dbQueue: batch.database.dbQueue
            )
            let locales = try await batch.database.dbQueue.read { db in
                try RecordingAudioSegmentRangeRecord.order(Column("startFrame")).fetchAll(db).map(\.localeIdentifier)
            }
            #expect(locales == ["ja_JP", "en_US"])
        }

        @Test
        func confirmationPreservesLocalesAcrossPendingSessions() async throws {
            let batch = try BatchAudioTestFixture(
                name: "pending-session-locales",
                endedAt: Date(timeIntervalSince1970: 1_776_384_001),
                duration: 1
            )
            defer { batch.removeFiles() }
            try await batch.recordMicrophoneAudio(localeIdentifier: "ja_JP")
            let secondSession = RecordingSessionRecord(
                id: .v7(),
                meetingId: batch.meeting.id,
                startedAt: batch.now.addingTimeInterval(2),
                endedAt: batch.now.addingTimeInterval(3),
                duration: 1,
                offsetSeconds: 2,
                createdAt: batch.now,
                updatedAt: batch.now,
                transcriptionMode: .batch
            )
            let segmentID = UUID.v7()
            try await batch.database.dbQueue.write { db in
                try secondSession.insert(db)
                try db.execute(
                    sql: """
                    INSERT INTO recording_audio_segments (
                        id, recordingSessionId, source, segmentIndex, generationId, state,
                        partialRelativePath, finalRelativePath, sampleRate, channelCount,
                        sessionStartOffsetSeconds, createdAt, updatedAt
                    ) VALUES (?, ?, ?, 0, ?, ?, ?, ?, 16000, 1, 0, ?, ?)
                    """,
                    arguments: [
                        segmentID,
                        secondSession.id,
                        RecordingAudioSource.microphone.rawValue,
                        UUID.v7(),
                        RecordingAudioSegmentState.ready.rawValue,
                        "second.partial.caf",
                        "second.caf",
                        batch.now,
                        batch.now,
                    ]
                )
                try RecordingAudioSegmentRangeRecord(
                    id: .v7(),
                    audioSegmentId: segmentID,
                    startFrame: 0,
                    frameCount: 1,
                    sessionOffsetSeconds: 0,
                    localeIdentifier: "en_US",
                    createdAt: batch.now,
                    updatedAt: batch.now
                ).insert(db)
            }

            let viewModel = CaptionViewModel()
            await viewModel.presentBatchTranscriptionConfirmation(
                sessionId: secondSession.id,
                meetingId: batch.meeting.id,
                dbQueue: batch.database.dbQueue
            )

            let confirmation = try #require(viewModel.pendingBatchTranscriptionConfirmation)
            #expect(confirmation.initialLanguageSelection == .recorded)
        }
    }
#endif
