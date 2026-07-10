import Foundation

struct BatchTranscriptionConfirmation: Identifiable, Equatable {
    let sessionId: UUID
    let meetingId: UUID
    let suggestedLocaleIdentifier: String

    var id: UUID { sessionId }
}
