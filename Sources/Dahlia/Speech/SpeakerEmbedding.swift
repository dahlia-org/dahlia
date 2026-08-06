import Foundation
import GRDB

struct SpeakerEmbeddingSpace: Codable, Hashable, Sendable {
    let provider: String
    let modelName: String
    let revision: String
    let assetFingerprint: String
    let fluidAudioVersion: String
    let dimensionCount: Int
    let sampleRate: Int
    let preprocessing: String
    let excludesOverlap: Bool
    let normalization: String
    let similarityDefinition: String
}

struct SpeakerEmbedding: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let space: SpeakerEmbeddingSpace
    let values: [Float]

    var description: String {
        "SpeakerEmbedding(space: \(space.modelName), dimensions: \(values.count), values: <redacted>)"
    }

    var debugDescription: String { description }

    func cosineSimilarity(to other: Self) -> SpeakerMatchResult {
        guard space == other.space else {
            return .unknown(.incompatibleEmbeddingSpace)
        }
        guard values.count == space.dimensionCount,
              other.values.count == space.dimensionCount else {
            return .unknown(.invalidEmbedding)
        }

        let score = zip(values, other.values).reduce(Float.zero) { $0 + $1.0 * $1.1 }
        return score.isFinite ? .candidate(score: score) : .unknown(.invalidEmbedding)
    }
}

struct MeetingSpeakerEvidence: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let speakerID: String
    let representative: SpeakerEmbedding
    let exemplars: [SpeakerEmbedding]
    let profileUpdateEligible: Bool
    let representativeSource: SpeakerRepresentativeSource

    init(
        speakerID: String,
        representative: SpeakerEmbedding,
        exemplars: [SpeakerEmbedding],
        profileUpdateEligible: Bool,
        representativeSource: SpeakerRepresentativeSource = .diarization
    ) {
        self.speakerID = speakerID
        self.representative = representative
        self.exemplars = exemplars
        self.profileUpdateEligible = profileUpdateEligible
        self.representativeSource = representativeSource
    }

    var description: String {
        "MeetingSpeakerEvidence(speakerID: \(speakerID), exemplars: \(exemplars.count), embeddings: <redacted>)"
    }

    var debugDescription: String { description }
}

enum SpeakerMatchResult: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    case candidate(score: Float)
    case matched(personID: UUID, score: Float)
    case unknown(SpeakerMatchUnknownReason)

    var description: String {
        switch self {
        case .candidate:
            "SpeakerMatchResult.candidate(score: <redacted>)"
        case .matched:
            "SpeakerMatchResult.matched(personID: <redacted>, score: <redacted>)"
        case let .unknown(reason):
            "SpeakerMatchResult.unknown(\(reason))"
        }
    }

    var debugDescription: String { description }
}

enum SpeakerMatchUnknownReason: String, Codable, DatabaseValueConvertible, Equatable, Error, Sendable {
    case analysisFailed
    case incompatibleEmbeddingSpace
    case insufficientEvidence
    case invalidEmbedding
    case belowThreshold
}

enum SpeakerAssignmentOrigin: String, Codable, DatabaseValueConvertible, Equatable, Sendable {
    case manual
    case suggestionApproved
    case ownerChannelConfirmation

    var isLearnable: Bool {
        switch self {
        case .manual, .suggestionApproved:
            true
        case .ownerChannelConfirmation:
            false
        }
    }
}
