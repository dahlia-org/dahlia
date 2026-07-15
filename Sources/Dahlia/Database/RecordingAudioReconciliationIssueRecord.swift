import Foundation
import GRDB

/// Local-only audit row for files or states that the reconciler deliberately leaves untouched.
struct RecordingAudioReconciliationIssueRecord: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "recording_audio_reconciliation_issues"

    var id: UUID
    var recordingSessionId: UUID?
    var audioSegmentId: UUID?
    var relativePath: String?
    var reason: String
    var firstObservedAt: Date
    var lastObservedAt: Date
    var resolvedAt: Date?
}
