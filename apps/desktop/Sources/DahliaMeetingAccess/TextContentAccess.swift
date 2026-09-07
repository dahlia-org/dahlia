import DahliaRuntimeSupport
import Foundation
import GRDB

/// Shared by the app and the read-only helper. Checking availability never performs network I/O.
public enum TextContentAccess {
    public static func availability(entity: TextContentEntity, id: UUID, in db: Database) throws -> TextContentAvailability {
        guard try db.tableExists("sync_content_state"),
              let row = try Row.fetchOne(db, sql: """
              SELECT c.*, s.confirmedRevision FROM sync_content_state c
              LEFT JOIN sync_entity_state s ON s.vaultId = c.vaultId AND s.entity = c.entity AND s.entityId = c.entityId
              WHERE c.entity = ? AND c.entityId = ?
              """, arguments: [entity.rawValue, id]) else { return .init(state: .ready) }
        let resident: Int? = row["residentRevision"]
        let latest: Int? = row["confirmedRevision"]
        let state: TextContentAvailability.State
        if row["fetchError"] as String? == TextContentError.deleted.rawValue {
            state = .deleted
        } else if !(row["present"] as Bool) || (entity == .transcript && row["complete"] as Bool && row["contentCount"] as Int? == 0) {
            state = .empty
        } else if !(row["complete"] as Bool) {
            let error: String? = row["fetchError"]
            state = switch error {
            case "loading": .loading
            case nil: .missing
            default: .failed
            }
        } else if latest != nil, resident != latest {
            state = .stale
        } else {
            state = .ready
        }
        return .init(state: state, revision: resident, latestRevision: latest)
    }

    public static func requireComplete(entity: TextContentEntity, id: UUID, in db: Database) throws {
        let state = try availability(entity: entity, id: id, in: db).state
        guard [.ready, .stale, .empty].contains(state) else { throw TextContentError.incomplete }
        if entity == .transcript,
           try Bool
           .fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM transcript_segments WHERE meetingId = ? AND text IS NULL)", arguments: [id]) == true {
            throw TextContentError.incomplete
        }
        if entity == .summary,
           try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM summaries WHERE meetingId = ? AND document IS NULL)", arguments: [id]) == true {
            throw TextContentError.incomplete
        }
    }

    public static func transcriptCount(meetingId: UUID, in db: Database) throws -> Int {
        let local = try Int.fetchOne(
            db,
            sql: "SELECT count(*) FROM transcript_segments WHERE meetingId = ? AND isConfirmed = 1",
            arguments: [meetingId]
        ) ?? 0
        guard try db.tableExists("sync_content_state") else { return local }
        let remote = try Int.fetchOne(
            db,
            sql: "SELECT contentCount FROM sync_content_state WHERE entity = 'transcript' AND entityId = ? AND complete = 0",
            arguments: [meetingId]
        ) ?? 0
        return max(local, remote)
    }
}
