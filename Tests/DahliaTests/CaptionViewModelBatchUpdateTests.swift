import Foundation
import GRDB
@preconcurrency import AVFoundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    @Suite(.serialized)
    struct CaptionViewModelBatchUpdateTests {
        private struct Fixture {
            let batch: BatchAudioTestFixture
            let recordingMeeting: MeetingRecord
            let recordingSegment: TranscriptSegmentRecord
            let visibleSegment: TranscriptSegmentRecord
        }

        @Test
        func completedBatchUpdateReplacesAwaitingConfirmationState() async throws {
            let prepared = try makeFixture(name: "completed-replaces-queued")
            let batch = prepared.batch
            defer { batch.removeFiles() }

            let viewModel = CaptionViewModel()
            viewModel.loadMeeting(
                batch.meeting.id,
                dbQueue: batch.database.dbQueue,
                projectURL: nil,
                projectId: nil,
                vaultURL: batch.vaultURL
            )

            #expect(await waitUntil {
                viewModel.batchTranscriptionState == .awaitingConfirmation(sessionId: batch.session.id)
            })

            _ = try completeBatchSessionAndInsertSegment(batch: batch)
            await viewModel.handleBatchTranscriptionUpdate(
                BatchTranscriptionUpdate(
                    meetingId: batch.meeting.id,
                    state: .completed(sessionId: batch.session.id)
                )
            )

            #expect(viewModel.batchTranscriptionState == nil)
        }

        @Test
        func completedBatchReloadsVisibleMeetingWhileAnotherMeetingIsRecording() async throws {
            let prepared = try makeFixture(name: "visible-batch")
            let batch = prepared.batch
            defer { batch.removeFiles() }

            let viewModel = CaptionViewModel()
            viewModel.loadMeeting(
                prepared.recordingMeeting.id,
                dbQueue: batch.database.dbQueue,
                projectURL: nil,
                projectId: nil,
                vaultURL: batch.vaultURL
            )
            #expect(await waitUntil {
                viewModel.store.segments.contains(where: { $0.id == prepared.recordingSegment.id })
            })

            viewModel.isListening = true
            viewModel.loadMeeting(
                batch.meeting.id,
                dbQueue: batch.database.dbQueue,
                projectURL: nil,
                projectId: nil,
                vaultURL: batch.vaultURL
            )
            #expect(await waitUntil {
                viewModel.store.segments.contains(where: { $0.id == prepared.visibleSegment.id })
            })
            #expect(viewModel.recordingMeetingId == prepared.recordingMeeting.id)
            #expect(viewModel.isViewingOtherWhileRecording)

            let completedSegment = try completeBatchSessionAndInsertSegment(batch: batch)
            await viewModel.handleBatchTranscriptionUpdate(
                BatchTranscriptionUpdate(
                    meetingId: batch.meeting.id,
                    state: .completed(sessionId: batch.session.id)
                )
            )

            #expect(viewModel.store.segments.contains(where: { $0.id == completedSegment.id }))
            #expect(viewModel.currentMeetingId == batch.meeting.id)
            #expect(viewModel.recordingMeetingId == prepared.recordingMeeting.id)
        }

        @Test
        // This regression test exercises the complete failed-batch recovery lifecycle.
        // swiftlint:disable:next function_body_length
        func discardingFailedBatchCancelsPendingSummaryGeneration() async throws {
            let previouslyGeneratesSummary = AppSettings.shared.generateSummaryAfterBatchTranscription
            AppSettings.shared.generateSummaryAfterBatchTranscription = true
            defer { AppSettings.shared.generateSummaryAfterBatchTranscription = previouslyGeneratesSummary }

            let batch = try BatchAudioTestFixture(
                name: "discard-cancels-summary",
                meetingStatus: .ready,
                endedAt: Date(timeIntervalSince1970: 1_776_384_001),
                duration: 1
            )
            defer { batch.removeFiles() }
            let recorder = try BatchAudioRecordingSession(
                dbQueue: batch.database.dbQueue,
                managedRootURL: batch.managedRootURL,
                meetingId: batch.meeting.id,
                recordingSessionId: batch.session.id,
                recordingStartTime: batch.now,
                sampleRate: 16000,
                configuration: RecordingAudioStore.Configuration(
                    targetSegmentDuration: .seconds(60),
                    maximumFinalizingSegmentCountPerSource: 2,
                    maximumActiveSegmentDuration: .seconds(600),
                    maximumActiveSegmentByteCount: 64 * 1_024 * 1_024,
                    minimumAvailableCapacity: 0,
                    capacityCheckInterval: .seconds(5)
                )
            )
            let writer = try await recorder.beginRange(
                source: .microphone,
                locale: Locale(identifier: "ja_JP"),
                at: batch.now
            )
            let buffer = try #require(
                AVAudioPCMBuffer(pcmFormat: recorder.targetFormat, frameCapacity: 160)
            )
            buffer.frameLength = 160
            writer.appendBuffer(buffer)
            try await recorder.finish()
            let audioSegment = try await batch.database.dbQueue.read { db in
                try #require(try RecordingAudioSegmentRecord.fetchOne(db))
            }
            let finalURL = batch.managedRootURL.appending(path: audioSegment.finalRelativePath)
            var damagedBytes = try Data(contentsOf: finalURL)
            damagedBytes[damagedBytes.index(before: damagedBytes.endIndex)] ^= 0x01
            try damagedBytes.write(to: finalURL)
            let existingSegment = TranscriptSegmentRecord(
                id: .v7(),
                meetingId: batch.meeting.id,
                startTime: batch.now,
                endTime: nil,
                text: "Existing transcript",
                translatedText: nil,
                isConfirmed: true,
                speakerLabel: "mic"
            )
            try await batch.database.dbQueue.write { db in
                try existingSegment.insert(db)
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
                viewModel.batchTranscriptionState == .awaitingConfirmation(sessionId: batch.session.id)
            })

            viewModel.pendingBatchTranscriptionConfirmation = BatchTranscriptionConfirmation(
                sessionId: batch.session.id,
                meetingId: batch.meeting.id,
                suggestedLocaleIdentifier: "ja_JP",
                retainAudioAfterBatch: false
            )
            viewModel.confirmBatchTranscription(
                languageSelection: .manual(localeIdentifier: "ja_JP"),
                retainAudioAfterBatch: false
            )
            #expect(await waitUntil {
                if case .failed = viewModel.batchTranscriptionState {
                    true
                } else {
                    false
                }
            })

            viewModel.discardFailedBatchTranscription()
            #expect(await waitUntil { viewModel.batchTranscriptionState == nil })

            viewModel.loadMeeting(
                batch.meeting.id,
                dbQueue: batch.database.dbQueue,
                projectURL: nil,
                projectId: nil,
                vaultURL: batch.vaultURL
            )
            #expect(await waitUntil {
                viewModel.store.segments.contains(where: { $0.id == existingSegment.id })
            })
            #expect(!viewModel.requestShowSummaryTab)
        }

        private func makeFixture(name: String) throws -> Fixture {
            let batch = try BatchAudioTestFixture(
                name: name,
                endedAt: Date(timeIntervalSince1970: 1_776_384_001),
                duration: 1
            )
            let recordingMeeting = MeetingRecord(
                id: .v7(),
                vaultId: batch.meeting.vaultId,
                projectId: nil,
                name: "active-recording",
                createdAt: batch.now.addingTimeInterval(-60),
                updatedAt: batch.now.addingTimeInterval(-60)
            )
            let recordingSegment = TranscriptSegmentRecord(
                id: .v7(),
                meetingId: recordingMeeting.id,
                startTime: recordingMeeting.createdAt,
                endTime: nil,
                text: "active recording transcript",
                translatedText: nil,
                isConfirmed: true,
                speakerLabel: "mic"
            )
            let visibleSegment = TranscriptSegmentRecord(
                id: .v7(),
                meetingId: batch.meeting.id,
                startTime: batch.now,
                endTime: nil,
                text: "visible transcript before completion",
                translatedText: nil,
                isConfirmed: true,
                speakerLabel: "mic"
            )
            try batch.database.dbQueue.write { db in
                try recordingMeeting.insert(db)
                try recordingSegment.insert(db)
                try visibleSegment.insert(db)
            }
            return Fixture(
                batch: batch,
                recordingMeeting: recordingMeeting,
                recordingSegment: recordingSegment,
                visibleSegment: visibleSegment
            )
        }

        private func completeBatchSessionAndInsertSegment(
            batch: BatchAudioTestFixture
        ) throws -> TranscriptSegmentRecord {
            let completedAt = batch.now.addingTimeInterval(2)
            let segment = TranscriptSegmentRecord(
                id: .v7(),
                meetingId: batch.meeting.id,
                startTime: completedAt,
                endTime: nil,
                text: "loaded after batch completion",
                translatedText: nil,
                isConfirmed: true,
                speakerLabel: "mic"
            )
            try batch.database.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE recording_sessions SET batchCompletedAt = ?, updatedAt = ? WHERE id = ?",
                    arguments: [completedAt, completedAt, batch.session.id]
                )
                try segment.insert(db)
            }
            return segment
        }

        private func waitUntil(
            timeout: Duration = .seconds(15),
            condition: () -> Bool
        ) async -> Bool {
            let clock = ContinuousClock()
            let deadline = clock.now + timeout

            while clock.now < deadline {
                if condition() {
                    return true
                }
                try? await Task.sleep(for: .milliseconds(10))
            }

            return condition()
        }
    }
#endif
