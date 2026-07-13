import Foundation

struct BatchTranscriptionConfirmation: Identifiable, Equatable {
    let sessionId: UUID
    let meetingId: UUID
    let suggestedLocaleIdentifier: String
    let retainAudioAfterBatch: Bool

    var id: UUID { sessionId }
}
