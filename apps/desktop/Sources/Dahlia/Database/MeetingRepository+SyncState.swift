import Foundation
import GRDB

enum MeetingSyncState: Equatable, Sendable {
    case local
    case pending
    case synced
    case recovering
    case updateRequired
    case blocked(SyncBlockedReason)
}

struct MeetingSyncSnapshot: Equatable, Sendable {
    struct Revision: FetchableRecord, Decodable, Equatable, Sendable {
        let entity: String
        let entityId: UUID
        let confirmedRevision: Int?
    }

    let connectionId: UUID?
    let state: MeetingSyncState
    let revisions: [Revision]
}

extension MeetingRepository {
    /// Only observes sync metadata. It never reads a transcript or image body to detect changes.
    nonisolated static func fetchMeetingSyncSnapshot(
        meetingId: UUID,
        in db: Database
    ) throws -> MeetingSyncSnapshot? {
        guard let meeting = try MeetingRecord.fetchOne(db, key: meetingId),
              let vault = try VaultRecord.fetchOne(db, key: meeting.vaultId) else { return nil }
        guard let connectionId = vault.accountConnectionId else {
            return MeetingSyncSnapshot(connectionId: nil, state: .local, revisions: [])
        }
        let blocked = try String.fetchOne(
            db,
            sql: "SELECT blockedReason FROM sync_transactions WHERE vaultId = ? AND blockedReason IS NOT NULL ORDER BY sequence LIMIT 1",
            arguments: [vault.id]
        ).flatMap(SyncBlockedReason.init(rawValue:))
        let hasPending = try SyncTransactionQueue.hasPending(vaultId: vault.id, in: db)
        let state: MeetingSyncState = if let blocked {
            .blocked(blocked)
        } else if vault.syncRecoveryState == "updateRequired" {
            .updateRequired
        } else if vault.syncRecoveryState != nil {
            .recovering
        } else if vault.syncConfirmedConnectionId != connectionId || vault.syncPullCursor == nil
            || hasPending {
            .pending
        } else {
            .synced
        }
        let revisions = try MeetingSyncSnapshot.Revision.fetchAll(
            db,
            sql: """
            SELECT entity, entityId, confirmedRevision FROM sync_entity_state
            WHERE vaultId = ? AND (
                (entity IN ('meeting', 'summary', 'transcript') AND entityId = ?)
                OR (entity = 'screenshot' AND entityId IN (SELECT id FROM screenshots WHERE meetingId = ?))
            ) ORDER BY entity, entityId
            """,
            arguments: [vault.id, meetingId, meetingId]
        )
        return MeetingSyncSnapshot(connectionId: connectionId, state: state, revisions: revisions)
    }
}
