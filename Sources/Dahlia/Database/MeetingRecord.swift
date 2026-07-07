import Foundation
import GRDB

/// ミーティングの状態。
enum MeetingStatus: String, Codable, DatabaseValueConvertible {
    case transcriptNotFound = "TRANSCRIPT_NOT_FOUND"
    case processingTranscript = "PROCESSING_TRANSCRIPT"
    case ready = "READY"

    static func fromDatabaseValue(_ dbValue: DatabaseValue) -> MeetingStatus? {
        guard let rawValue = String.fromDatabaseValue(dbValue),
              let status = normalized(rawValue: rawValue)
        else {
            return nil
        }
        return status
    }

    var databaseValue: DatabaseValue {
        rawValue.databaseValue
    }

    private static func normalized(rawValue: String) -> MeetingStatus? {
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "TRANSCRIPT_NOT_FOUND":
            .transcriptNotFound
        case "PROCESSING_TRANSCRIPT":
            .processingTranscript
        case "READY", "RECORDING":
            .ready
        default:
            nil
        }
    }
}

/// ミーティングセッションを表す GRDB レコード。
struct MeetingRecord: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "meetings"

    var id: UUID
    var vaultId: UUID
    var projectId: UUID?
    var name: String
    var status: MeetingStatus = .transcriptNotFound
    var duration: TimeInterval?
    var createdAt: Date
    var updatedAt: Date
}
