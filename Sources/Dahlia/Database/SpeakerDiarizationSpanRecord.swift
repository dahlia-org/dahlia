import Foundation
import GRDB

struct SpeakerDiarizationSpanRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable {
    static let databaseTableName = "speaker_diarization_spans"

    var id: UUID
    var meetingSpeakerId: UUID
    var startSeconds: Double
    var endSeconds: Double
    var createdAt: Date
}
