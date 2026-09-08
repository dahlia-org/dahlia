import DahliaMeetingAccess
import Foundation
import GRDB

extension TranscriptContent {
    init(from segment: TranscriptSegment, meetingId: UUID, defaultSessionId: UUID? = nil) {
        self.init(
            id: segment.id, meetingId: meetingId, sessionId: segment.sessionId ?? defaultSessionId,
            startTime: segment.startTime, endTime: segment.endTime, text: segment.text,
            translatedText: segment.translatedText, isConfirmed: segment.isConfirmed,
            audioSource: segment.audioSource, speakerLabel: segment.speakerLabel,
            audioFeatureVersion: segment.audioFeatures?.version,
            audioActiveRmsDecibels: segment.audioFeatures?.activeRmsDecibels,
            audioMedianPitchHertz: segment.audioFeatures?.medianPitchHertz,
            audioVoicedFrameRatio: segment.audioFeatures?.voicedFrameRatio,
            audioPitchSpreadHertz: segment.audioFeatures?.pitchSpreadHertz,
            createdAt: segment.createdAt
        )
    }

    /// Called inside the durable writer's transaction, together with its sync operation.
    func insert(_ db: Database) throws {
        guard isConfirmed else { return }
        try TranscriptSegmentRecord(from: TranscriptSegment(from: self), meetingId: meetingId).insert(db)
        try TranscriptSegmentBodyRecord(segmentId: id, text: text).insert(db)
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

}
