import Foundation

/// A read-only speaker identity projection for one meeting transcript.
struct TranscriptSpeakerIdentity: Equatable {
    let meetingSpeakerId: UUID
    let ordinal: Int
    let assignedContactName: String?
    let referenceContactName: String?

    var stableColorIndex: Int {
        meetingSpeakerId.uuidString.utf8.reduce(0) { ($0 &* 31 &+ Int($1)) % 8 }
    }
}
