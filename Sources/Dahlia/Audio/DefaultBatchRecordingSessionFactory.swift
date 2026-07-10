import Foundation
import GRDB

/// CAF batch recorderを生成するdefault factory。
struct DefaultBatchRecordingSessionFactory: BatchRecordingSessionFactory {
    @MainActor
    func makeSession(
        dbQueue: DatabaseQueue,
        managedRootURL: URL,
        meetingId: UUID,
        recordingSessionId: UUID,
        recordingStartTime: Date,
        sampleRate: Double
    ) throws -> any BatchRecordingSession {
        try DefaultBatchRecordingSession(session: BatchAudioRecordingSession(
            dbQueue: dbQueue,
            managedRootURL: managedRootURL,
            meetingId: meetingId,
            recordingSessionId: recordingSessionId,
            recordingStartTime: recordingStartTime,
            sampleRate: sampleRate
        ))
    }
}
