import Foundation
import GRDB

struct VaultSyncProgress: Identifiable, Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case preparing, text, attachments, fetching, retrying, attention, synced
    }

    let id: UUID
    let name: String
    let state: MeetingSyncState
    let phase: Phase
    let errorCode: String?
    let meetings: Int
    let files: Int
    let attachments: Int
    let other: Int

    var remaining: Int { meetings + files + attachments + other }
}

struct AccountSyncProgress: Equatable, Sendable {
    let vaults: [VaultSyncProgress]

    var state: MeetingSyncState {
        vaults.map(\.state).max { $0.accountPriority < $1.accountPriority } ?? .pending
    }

    var remaining: Int { vaults.reduce(0) { $0 + $1.remaining } }
}

extension MeetingRepository {
    /// Counts only immutable operation identifiers, never transcript, summary, or image bodies.
    nonisolated static func fetchSyncProgress(in db: Database) throws -> [UUID: AccountSyncProgress] {
        let vaults = try VaultRecord.filter(Column("accountConnectionId") != nil).order(Column("createdAt"), Column("id")).fetchAll(db)
        var accounts: [UUID: [VaultSyncProgress]] = [:]
        for vault in vaults {
            guard let connectionId = vault.accountConnectionId else { continue }
            let counts = try Row.fetchAll(db, sql: """
            SELECT category, count(*) AS count FROM (
                SELECT DISTINCT CASE
                    WHEN o.entity IN ('meeting', 'summary', 'transcript') THEN 'meeting'
                    WHEN o.entity IN ('file', 'meeting_attachment') THEN o.entity
                    ELSE 'other' END AS category,
                    CASE WHEN o.entity IN ('meeting', 'summary', 'transcript') THEN 'meeting' ELSE o.entity END AS entity,
                    o.entityId
                FROM sync_transactions t JOIN sync_operations o ON o.transactionId = t.id
                WHERE t.vaultId = ? AND t.connectionId = ?
            ) GROUP BY category
            """, arguments: [vault.id, connectionId])
            let remaining = Dictionary(uniqueKeysWithValues: counts.map { ($0["category"] as String, $0["count"] as Int) })
            let head = try Row.fetchOne(db, sql: """
            SELECT t.leaseExpiresAt, t.serverResponseJSON,
                CASE WHEN json_valid(t.serverResponseJSON)
                    THEN json_extract(t.serverResponseJSON, '$.code') END AS errorCode,
                EXISTS(SELECT 1 FROM sync_operations o WHERE o.transactionId = t.id
                    AND o.entity IN ('file', 'meeting_attachment', 'recording')) AS attachment,
                EXISTS(SELECT 1 FROM sync_operations o WHERE o.transactionId = t.id
                    AND o.entity IN ('meeting', 'summary', 'transcript')) AS text
            FROM sync_transactions t WHERE t.vaultId = ? AND t.connectionId = ? ORDER BY t.sequence LIMIT 1
            """, arguments: [vault.id, connectionId])
            let state = try fetchVaultSyncState(vault, in: db)
            let phase: VaultSyncProgress.Phase
            switch state {
            case .blocked, .updateRequired, .relocationPaused:
                phase = .attention
            case .synced:
                phase = .synced
            default:
                if vault.syncConfirmedConnectionId != connectionId {
                    phase = .preparing
                } else if let head {
                    let retry: String? = head["serverResponseJSON"]
                    let lease: Date? = head["leaseExpiresAt"]
                    if retry != nil, lease == nil {
                        phase = .retrying
                    } else if head["attachment"] as Bool, !(head["text"] as Bool) {
                        phase = .attachments
                    } else {
                        phase = .text
                    }
                } else {
                    phase = .fetching
                }
            }
            accounts[connectionId, default: []].append(.init(
                id: vault.id, name: vault.name, state: state, phase: phase,
                errorCode: head?["errorCode"],
                meetings: remaining["meeting", default: 0], files: remaining["file", default: 0],
                attachments: remaining["meeting_attachment", default: 0], other: remaining["other", default: 0]
            ))
        }
        return accounts.mapValues { AccountSyncProgress(vaults: $0) }
    }
}
