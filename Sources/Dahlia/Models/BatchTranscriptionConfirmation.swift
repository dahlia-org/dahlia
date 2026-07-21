import Foundation

struct BatchTranscriptionConfirmation: Identifiable, Equatable {
    let sessionId: UUID
    let meetingId: UUID
    let suggestedLocaleIdentifier: String
    let retainAudioAfterBatch: Bool
    let initialLanguageSelection: BatchTranscriptionLanguageSelection

    init(
        sessionId: UUID,
        meetingId: UUID,
        suggestedLocaleIdentifier: String,
        retainAudioAfterBatch: Bool,
        initialLanguageSelection: BatchTranscriptionLanguageSelection = .automatic
    ) {
        self.sessionId = sessionId
        self.meetingId = meetingId
        self.suggestedLocaleIdentifier = suggestedLocaleIdentifier
        self.retainAudioAfterBatch = retainAudioAfterBatch
        self.initialLanguageSelection = initialLanguageSelection
    }

    var id: UUID { sessionId }
}
