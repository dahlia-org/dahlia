import Foundation
import GRDB

/// ひとつづきの録音セッションを表す GRDB レコード。
struct RecordingSessionRecord: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "recording_sessions"

    var id: UUID
    var meetingId: UUID
    var startedAt: Date
    var endedAt: Date?
    var duration: TimeInterval?
    var offsetSeconds: TimeInterval
    var createdAt: Date
    var updatedAt: Date
    var transcriptionMode: TranscriptionMode = .realtime
    var retainAudioAfterBatch = false
    var batchCompletedAt: Date?
    var batchLastError: String?
    var batchLastAttemptAt: Date?
    var batchAttemptCount = 0
    var batchDiscardedAt: Date?
    var audioRetentionPolicy: RecordingAudioRetentionPolicy?
    var retentionExpiresAt: Date?
    var batchFailureKind: BatchFailureKind?
    var batchLanguageDetectionMode: BatchLanguageDetectionMode = .manual
    var batchSelectedLocaleIdentifier: String?
    var batchAutomaticLanguageCandidatesJSON: String?

    /// A completed transcript is being rebuilt while the previous successful result remains available.
    var isBatchRetranscriptionPending: Bool {
        guard let batchCompletedAt, let batchLastAttemptAt else { return false }
        return batchLastAttemptAt > batchCompletedAt
    }
}
