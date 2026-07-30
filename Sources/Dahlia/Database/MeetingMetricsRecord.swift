import Foundation
import GRDB

struct MeetingMetricsRecord: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    static let databaseTableName = "meeting_metrics"

    var meetingId: UUID
    var metricsVersion: Int
    var transcriptRevision: Int64
    var conversationTalkSeconds: Double
    var overlapSeconds: Double?
    var talkBalance: Double?
    var confirmedSegmentCount: Int
    var validSegmentCount: Int
    var invalidDurationSegmentCount: Int
    var unknownSourceSegmentCount: Int
    var totalCharacterCount: Int
    var validCharacterCount: Int
    var unknownSourceCharacterCount: Int

    init(_ result: MeetingMetricsResult) {
        meetingId = result.meetingId
        metricsVersion = result.metricsVersion
        transcriptRevision = result.transcriptRevision
        conversationTalkSeconds = result.conversationTalkSeconds
        overlapSeconds = result.overlapSeconds
        talkBalance = result.talkBalance
        confirmedSegmentCount = result.confirmedSegmentCount
        validSegmentCount = result.validSegmentCount
        invalidDurationSegmentCount = result.invalidDurationSegmentCount
        unknownSourceSegmentCount = result.unknownSourceSegmentCount
        totalCharacterCount = result.totalCharacterCount
        validCharacterCount = result.validCharacterCount
        unknownSourceCharacterCount = result.unknownSourceCharacterCount
    }
}

extension MeetingMetricsResult {
    init(
        _ record: MeetingMetricsRecord,
        sourceRows: [MeetingSourceMetricsRow],
        isPartialAnalysis: Bool
    ) {
        meetingId = record.meetingId
        metricsVersion = record.metricsVersion
        transcriptRevision = record.transcriptRevision
        conversationTalkSeconds = record.conversationTalkSeconds
        overlapSeconds = record.overlapSeconds
        talkBalance = record.talkBalance
        confirmedSegmentCount = record.confirmedSegmentCount
        validSegmentCount = record.validSegmentCount
        invalidDurationSegmentCount = record.invalidDurationSegmentCount
        unknownSourceSegmentCount = record.unknownSourceSegmentCount
        totalCharacterCount = record.totalCharacterCount
        validCharacterCount = record.validCharacterCount
        unknownSourceCharacterCount = record.unknownSourceCharacterCount
        self.sourceRows = sourceRows
        self.isPartialAnalysis = isPartialAnalysis
    }
}
