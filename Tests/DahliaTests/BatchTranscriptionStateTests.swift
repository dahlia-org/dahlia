import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct BatchTranscriptionStateTests {
        @Test
        func derivesStateFromDurableFacts() {
            let now = Date(timeIntervalSince1970: 1_776_384_000)
            var session = RecordingSessionRecord(
                id: .v7(),
                meetingId: .v7(),
                startedAt: now,
                endedAt: nil,
                duration: nil,
                offsetSeconds: 0,
                createdAt: now,
                updatedAt: now,
                transcriptionMode: .batch
            )

            #expect(BatchTranscriptionState.derive(from: session) == .recording(sessionId: session.id))

            session.endedAt = now.addingTimeInterval(10)
            #expect(BatchTranscriptionState.derive(from: session) == .awaitingConfirmation(sessionId: session.id))
            #expect(BatchTranscriptionState.derive(from: session, isRunning: true) == .running(sessionId: session.id))

            session.batchLastAttemptAt = now.addingTimeInterval(11)
            #expect(BatchTranscriptionState.derive(from: session) == .queued(sessionId: session.id))

            session.batchLastError = "damaged"
            #expect(BatchTranscriptionState.derive(from: session) == .failed(sessionId: session.id, message: "damaged"))

            session.batchCompletedAt = now.addingTimeInterval(20)
            #expect(BatchTranscriptionState.derive(from: session) == .completed(sessionId: session.id))

            session.batchDiscardedAt = now.addingTimeInterval(30)
            #expect(BatchTranscriptionState.derive(from: session) == nil)
        }

        @Test
        func realtimeSessionHasNoBatchState() {
            let now = Date(timeIntervalSince1970: 1_776_384_000)
            let session = RecordingSessionRecord(
                id: .v7(),
                meetingId: .v7(),
                startedAt: now,
                endedAt: now,
                duration: 0,
                offsetSeconds: 0,
                createdAt: now,
                updatedAt: now
            )

            #expect(BatchTranscriptionState.derive(from: session) == nil)
        }

        @Test
        func automaticRetryStopsAfterThreeRecordedFailures() {
            let now = Date(timeIntervalSince1970: 1_776_384_000)
            var session = RecordingSessionRecord(
                id: .v7(),
                meetingId: .v7(),
                startedAt: now,
                endedAt: now.addingTimeInterval(10),
                duration: 10,
                offsetSeconds: 0,
                createdAt: now,
                updatedAt: now,
                transcriptionMode: .batch,
                batchLastError: "damaged",
                batchAttemptCount: 2
            )

            #expect(BatchTranscriptionCoordinator.shouldAutomaticallyRetry(session))

            session.batchAttemptCount = BatchTranscriptionCoordinator.maximumAutomaticAttemptCount
            #expect(!BatchTranscriptionCoordinator.shouldAutomaticallyRetry(session))

            // 実行中クラッシュでエラーが記録されなかったセッションは、回数にかかわらず復旧対象にする。
            session.batchLastError = nil
            session.batchLastAttemptAt = now.addingTimeInterval(11)
            #expect(BatchTranscriptionCoordinator.shouldAutomaticallyRetry(session))

            // 停止後にまだ確認されていないセッションは、再起動しても自動実行しない。
            session.batchLastAttemptAt = nil
            session.batchAttemptCount = 0
            #expect(!BatchTranscriptionCoordinator.shouldAutomaticallyRetry(session))
        }
    }
#endif
