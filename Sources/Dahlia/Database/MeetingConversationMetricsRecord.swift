import Foundation
import GRDB

struct MeetingConversationMetricsRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "meeting_conversation_metrics"

    var meetingId: UUID
    var calculationVersion: Int
    var inputFingerprint: String
    var recordingDuration: TimeInterval
    var unionSpeechDuration: TimeInterval
    var overlapDuration: TimeInterval
    var usesLegacyTimelineFallback: Bool
    var computedAt: Date
}
