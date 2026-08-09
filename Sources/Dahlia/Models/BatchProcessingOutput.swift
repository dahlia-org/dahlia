import Foundation

struct BatchProcessingOutput: Sendable {
    struct SpeakerAnalysis: Sendable {
        let sources: [SourceAnalysis]
    }

    struct SourceAnalysis: Sendable {
        let id: UUID
        let audioSource: RecordingAudioSource
        let embeddingSpace: SpeakerEmbeddingSpace?
        let speakers: [Speaker]
        let failureReason: SpeakerMatchUnknownReason?

        var succeeded: Bool { failureReason == nil }
    }

    struct Speaker: Sendable {
        let id: UUID
        let localSpeakerId: String
        let representative: SpeakerEmbedding
        let representativeQuality: Float
        let representativeSource: SpeakerRepresentativeSource
        let profileUpdateEligible: Bool
        let exemplars: [SpeakerEmbeddingExemplar]
        let spans: [SpeakerDiarizationSpan]
    }

    let transcriptSegments: [TranscriptSegment]
    let speakerAnalysis: SpeakerAnalysis?
    let transcriptSpeakerAssignments: [UUID: UUID]
}
