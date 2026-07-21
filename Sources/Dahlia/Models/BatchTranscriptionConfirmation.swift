import Foundation

struct BatchTranscriptionConfirmation: Identifiable, Equatable {
    let sessionId: UUID
    let meetingId: UUID
    let suggestedLocaleIdentifier: String
    let retainAudioAfterBatch: Bool
    let initialLanguageSelection: BatchTranscriptionLanguageSelection
    let automaticLanguageCandidateSnapshot: BatchLanguageDetectionCandidateSnapshot?

    init(
        sessionId: UUID,
        meetingId: UUID,
        suggestedLocaleIdentifier: String,
        retainAudioAfterBatch: Bool,
        initialLanguageSelection: BatchTranscriptionLanguageSelection? = nil,
        automaticLanguageCandidateSnapshot: BatchLanguageDetectionCandidateSnapshot? = nil
    ) {
        self.sessionId = sessionId
        self.meetingId = meetingId
        self.suggestedLocaleIdentifier = suggestedLocaleIdentifier
        self.retainAudioAfterBatch = retainAudioAfterBatch
        self.initialLanguageSelection = initialLanguageSelection
            ?? .manual(localeIdentifier: suggestedLocaleIdentifier)
        self.automaticLanguageCandidateSnapshot = automaticLanguageCandidateSnapshot
    }

    var id: UUID { sessionId }
}
