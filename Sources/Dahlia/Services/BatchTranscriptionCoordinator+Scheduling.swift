import Foundation

extension BatchTranscriptionCoordinator: BatchTranscriptionScheduling {
    func notify(meetingId: UUID, state: BatchTranscriptionState) async {
        await onStateChange(BatchTranscriptionUpdate(meetingId: meetingId, state: state))
    }

    static func shouldAutomaticallyRetry(_ session: RecordingSessionRecord) -> Bool {
        guard session.transcriptionMode == .batch,
              session.batchCompletedAt == nil,
              session.batchDiscardedAt == nil else { return false }
        guard session.batchFailureKind != .recordingRecovery,
              session.batchFailureKind != .recordingAudioPermanent else { return false }
        guard session.batchLastAttemptAt != nil || session.batchLastError?.nilIfBlank != nil else {
            return false
        }
        guard session.batchLastError?.nilIfBlank != nil else { return true }
        return session.batchAttemptCount < maximumAutomaticAttemptCount
    }
}
