import Foundation
import GRDB

struct MeetingSourceMetricsRecord: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    static let databaseTableName = "meeting_source_metrics"

    var meetingId: UUID
    var source: MetricsSource
    var speakingSeconds: Double
    var characterCount: Int
    var cjkCharacterCount: Int
    var turnCount: Int
    var charactersPerMinute: Double?

    init(_ row: MeetingSourceMetricsRow) {
        meetingId = row.meetingId
        source = row.source
        speakingSeconds = row.speakingSeconds
        characterCount = row.characterCount
        cjkCharacterCount = row.cjkCharacterCount
        turnCount = row.turnCount
        charactersPerMinute = row.charactersPerMinute
    }
}

extension MeetingSourceMetricsRow {
    init(_ record: MeetingSourceMetricsRecord) {
        meetingId = record.meetingId
        source = record.source
        speakingSeconds = record.speakingSeconds
        characterCount = record.characterCount
        cjkCharacterCount = record.cjkCharacterCount
        turnCount = record.turnCount
        charactersPerMinute = record.charactersPerMinute
    }
}
