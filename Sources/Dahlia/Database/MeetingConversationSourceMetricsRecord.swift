import Foundation
import GRDB

struct MeetingConversationSourceMetricsRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "meeting_conversation_source_metrics"

    var meetingId: UUID
    var source: RecordingAudioSource
    var speechDuration: TimeInterval
    var normalizedCharacterCount: Int
    var segmentCount: Int
    var unmeasurableSegmentCount: Int
}
