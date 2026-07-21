import Foundation

struct BatchTranscriptionConfirmation: Identifiable, Equatable {
    enum Purpose: Equatable {
        case initialOrRetry
        case retranscription(sessionIds: [UUID])
    }

    let sessionId: UUID
    let meetingId: UUID
    let suggestedLocaleIdentifier: String
    let retainAudioAfterBatch: Bool
    let initialLanguageSelection: BatchTranscriptionLanguageSelection
    let automaticLanguageCandidateSnapshot: BatchLanguageDetectionCandidateSnapshot?
    let purpose: Purpose
    let initiallyGeneratesSummary: Bool

    init(
        sessionId: UUID,
        meetingId: UUID,
        suggestedLocaleIdentifier: String,
        retainAudioAfterBatch: Bool,
        initialLanguageSelection: BatchTranscriptionLanguageSelection? = nil,
        automaticLanguageCandidateSnapshot: BatchLanguageDetectionCandidateSnapshot? = nil,
        purpose: Purpose = .initialOrRetry,
        initiallyGeneratesSummary: Bool = false
    ) {
        if case let .retranscription(sessionIds) = purpose {
            precondition(!sessionIds.isEmpty && sessionIds.contains(sessionId))
        }
        self.sessionId = sessionId
        self.meetingId = meetingId
        self.suggestedLocaleIdentifier = suggestedLocaleIdentifier
        self.retainAudioAfterBatch = retainAudioAfterBatch
        self.initialLanguageSelection = initialLanguageSelection
            ?? .manual(localeIdentifier: suggestedLocaleIdentifier)
        self.automaticLanguageCandidateSnapshot = automaticLanguageCandidateSnapshot
        self.purpose = purpose
        self.initiallyGeneratesSummary = initiallyGeneratesSummary
    }

    var id: UUID { sessionId }

    var isRetranscription: Bool {
        if case .retranscription = purpose { true } else { false }
    }
}
