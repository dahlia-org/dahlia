import Foundation
import GRDB

/// 文字起こしセグメントを表す GRDB レコード。
struct TranscriptSegmentRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "transcript_segments"

    var id: UUID
    var meetingId: UUID
    var sessionId: UUID? = nil
    var startTime: Date
    var endTime: Date?
    var text: String
    var translatedText: String?
    var isConfirmed: Bool
    var speakerLabel: String?
    var audioFeatureVersion: Int? = nil
    var audioActiveRmsDecibels: Double? = nil
    var audioMedianPitchHertz: Double? = nil
    var audioVoicedFrameRatio: Double? = nil
    var audioPitchSpreadHertz: Double? = nil
}

extension TranscriptSegmentRecord {
    /// TranscriptSegment から TranscriptSegmentRecord を生成する。
    init(from segment: TranscriptSegment, meetingId: UUID, defaultSessionId: UUID? = nil) {
        self.id = segment.id
        self.meetingId = meetingId
        self.sessionId = segment.sessionId ?? defaultSessionId
        self.startTime = segment.startTime
        self.endTime = segment.endTime
        self.text = segment.text
        self.translatedText = segment.translatedText
        self.isConfirmed = segment.isConfirmed
        self.speakerLabel = segment.speakerLabel
        self.audioFeatureVersion = segment.audioFeatures?.version
        self.audioActiveRmsDecibels = segment.audioFeatures?.activeRmsDecibels
        self.audioMedianPitchHertz = segment.audioFeatures?.medianPitchHertz
        self.audioVoicedFrameRatio = segment.audioFeatures?.voicedFrameRatio
        self.audioPitchSpreadHertz = segment.audioFeatures?.pitchSpreadHertz
    }

    var audioFeatures: TranscriptAudioFeatures? {
        guard let audioFeatureVersion,
              let audioVoicedFrameRatio else { return nil }
        return TranscriptAudioFeatures(
            version: audioFeatureVersion,
            activeRmsDecibels: audioActiveRmsDecibels,
            medianPitchHertz: audioMedianPitchHertz,
            voicedFrameRatio: audioVoicedFrameRatio,
            pitchSpreadHertz: audioPitchSpreadHertz
        )
    }

    static func updateTranslatedText(
        _ translatedText: String?,
        id: UUID,
        in db: Database
    ) throws {
        try db.execute(
            sql: "UPDATE transcript_segments SET translatedText = ? WHERE id = ?",
            arguments: [translatedText, id]
        )
    }
}
