import Foundation
import GRDB

struct TranscriptSegmentBodyRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "transcript_segment_bodies"

    var segmentId: UUID
    var text: String
}
