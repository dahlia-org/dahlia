import Foundation
import GRDB

struct MeetingSpeakerRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable {
    static let databaseTableName = "meeting_speakers"

    var id: UUID
    var analysisId: UUID
    var localSpeakerId: String
    var representative: Data
    var representativeQuality: Double
    var representativeSource: SpeakerRepresentativeSource
    var profileUpdateEligible: Bool
    var revision: Int
    var createdAt: Date
    var updatedAt: Date
}
