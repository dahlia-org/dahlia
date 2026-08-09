import Foundation
import GRDB

enum SpeakerAnalysisState: String, Codable, DatabaseValueConvertible, Sendable {
    case succeeded
    case failed
}

enum SpeakerRepresentativeSource: String, Codable, DatabaseValueConvertible, Sendable {
    case diarization
    case speakerDatabase
}

enum SpeakerMatchObservationState: String, Codable, DatabaseValueConvertible, Sendable {
    case referenceOnly
    case suggested
    case rejected
    case undeterminable
}

enum SpeakerMatchPolicyState: String, Codable, DatabaseValueConvertible, Sendable {
    case calibrationRequired
    case calibrated
}

struct SpeakerMatchPolicy: Equatable, Sendable {
    static let formatVersion = 1
    static let calibrationRequired = Self(
        formatVersion: formatVersion,
        state: .calibrationRequired,
        minimumSimilarity: nil,
        minimumMargin: nil
    )

    let formatVersion: Int
    let state: SpeakerMatchPolicyState
    let minimumSimilarity: Float?
    let minimumMargin: Float?
}

struct SpeakerCandidate: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let meetingSpeakerId: UUID
    let meetingId: UUID
    let audioSource: RecordingAudioSource
    let localSpeakerId: String
    let revision: Int
    let assignedContactId: UUID?
    let assignmentOrigin: SpeakerAssignmentOrigin?
    let top1ContactId: UUID?
    let top1Score: Float?
    let top2ContactId: UUID?
    let top2Score: Float?
    let margin: Float?
    let matchState: SpeakerMatchObservationState?
    let unknownReason: SpeakerMatchUnknownReason?

    var description: String {
        "SpeakerCandidate(meetingSpeakerId: \(meetingSpeakerId), meetingId: \(meetingId), audioSource: \(audioSource), localSpeakerId: \(localSpeakerId), revision: \(revision), assignmentOrigin: \(String(describing: assignmentOrigin)), matchState: \(String(describing: matchState)), unknownReason: \(String(describing: unknownReason)), contactIdsAndScores: <redacted>)"
    }

    var debugDescription: String { description }
}

enum SpeakerIdentityError: Error, Equatable {
    case candidateNotFound
    case contactNotFound
    case embeddingSpaceNotFound
    case invalidEmbedding
    case invalidSuggestion
    case revisionConflict
    case vaultNotFound
}

struct SpeakerMatchRanking: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let top1ContactId: UUID?
    let top1Score: Float?
    let top2ContactId: UUID?
    let top2Score: Float?
    let margin: Float?
    let state: SpeakerMatchObservationState
    let unknownReason: SpeakerMatchUnknownReason?

    var description: String {
        "SpeakerMatchRanking(state: \(state), unknownReason: \(String(describing: unknownReason)), contactIdsAndScores: <redacted>)"
    }

    var debugDescription: String { description }
}
