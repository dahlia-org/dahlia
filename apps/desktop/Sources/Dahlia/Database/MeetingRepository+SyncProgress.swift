import DahliaRuntimeSupport
import Foundation
import GRDB

struct SyncRecordTarget: Equatable, Sendable {
    let entity: SyncEntity
    let id: UUID
}

struct SyncProgressIssue: Identifiable, Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case discovery
        case pull
        case queue(SyncBlockedReason)
    }

    let source: Source
    let status: Int?
    let code: String
    let target: SyncRecordTarget?

    var id: String {
        let sourceId = switch source {
        case .discovery: "discovery"
        case .pull: "pull"
        case let .queue(reason): "queue-\(reason.rawValue)"
        }
        return "\(sourceId)-\(code)-\(target?.id.uuidString ?? "account")"
    }
}

struct SyncDiscardImpact: Equatable, Sendable {
    let transactions: Int
    let operations: Int
    let records: Int
    let localBodies: Int
    let meetings: Int
    let lastTransactionId: UUID
    let hasConfirmedWorkspace: Bool
}

struct SyncRecordingArchiveFailure: FetchableRecord, Decodable, Identifiable, Equatable, Sendable {
    let meetingId: UUID
    let meetingName: String
    let code: String?

    var id: UUID { meetingId }
}

struct WorkspaceSyncProgress: Identifiable, Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case preparing, text, attachments, fetching, retrying, attention, synced
    }

    let id: UUID
    let name: String
    let state: MeetingSyncState
    let phase: Phase
    let issues: [SyncProgressIssue]
    let allowsCanonicalEdits: Bool
    let retryAt: Date?
    let retryErrorCode: String?
    let discardImpact: SyncDiscardImpact?
    let recordingArchiveFailures: [SyncRecordingArchiveFailure]
    let meetings: Int
    let files: Int
    let attachments: Int
    let other: Int

    var errorCode: String? { issues.first?.code }
    var remaining: Int { meetings + files + attachments + other }

    var allowsRecordingArchiveRetry: Bool {
        guard allowsCanonicalEdits else { return false }
        switch state {
        case .recovering, .updateRequired, .relocationPaused:
            return false
        default:
            return true
        }
    }
}

struct AccountSyncProgress: Equatable, Sendable {
    let discoveryIssue: SyncProgressIssue?
    let workspaces: [WorkspaceSyncProgress]

    init(discoveryIssue: SyncProgressIssue? = nil, workspaces: [WorkspaceSyncProgress]) {
        self.discoveryIssue = discoveryIssue
        self.workspaces = workspaces
    }

    var state: MeetingSyncState {
        if allIssues.contains(where: { $0.status == 401 || $0.status == 403 }) {
            return .blocked(.authorization)
        }
        let state = workspaces.map(\.state).max { $0.accountPriority < $1.accountPriority } ?? .pending
        return state == .synced && hasAttention ? .pending : state
    }

    var hasAttention: Bool {
        !allIssues.isEmpty || workspaces.contains { !$0.recordingArchiveFailures.isEmpty && $0.allowsRecordingArchiveRetry }
    }

    var remaining: Int { workspaces.reduce(0) { $0 + $1.remaining } }

    private var allIssues: [SyncProgressIssue] {
        (discoveryIssue.map { [$0] } ?? []) + workspaces.flatMap(\.issues)
    }
}

extension MeetingRepository {
    /// Counts only immutable operation identifiers and recovery metadata, never transcript, summary, or image bodies.
    nonisolated static func fetchSyncProgress(in db: Database) throws -> [UUID: AccountSyncProgress] {
        let connections = try DahliaAccountConnectionRecord.order(Column("createdAt"), Column("id")).fetchAll(db)
        let workspaces = try WorkspaceRecord
            .filter(Column("accountConnectionId") != nil)
            .order(Column("createdAt"), Column("id"))
            .fetchAll(db)
        var accounts = Dictionary(uniqueKeysWithValues: connections.map { connection in
            let incident = SyncIncident(jsonString: connection.syncDiscoveryErrorJSON)
            let issue = incident.map {
                SyncProgressIssue(
                    source: .discovery,
                    status: $0.status,
                    code: $0.code,
                    target: nil
                )
            }
            return (connection.id, AccountSyncProgress(discoveryIssue: issue, workspaces: []))
        })

        for workspace in workspaces {
            guard let connectionId = workspace.accountConnectionId else { continue }
            let counts = try Row.fetchAll(db, sql: """
            SELECT category, count(*) AS count FROM (
                SELECT DISTINCT CASE
                    WHEN o.entity IN ('meeting', 'summary', 'transcript') THEN 'meeting'
                    WHEN o.entity IN ('file', 'meeting_attachment') THEN o.entity
                    ELSE 'other' END AS category,
                    CASE WHEN o.entity IN ('meeting', 'summary', 'transcript') THEN 'meeting' ELSE o.entity END AS entity,
                    o.entityId
                FROM sync_transactions t JOIN sync_operations o ON o.transactionId = t.id
                WHERE t.workspace_id = ? AND t.connectionId = ?
            ) GROUP BY category
            """, arguments: [workspace.id, connectionId])
            let remaining = Dictionary(uniqueKeysWithValues: counts.map { ($0["category"] as String, $0["count"] as Int) })
            let head = try Row.fetchOne(db, sql: """
            SELECT t.id, t.sequence, t.availableAt, t.leaseExpiresAt, t.serverResponseJSON, t.blockedReason,
                EXISTS(SELECT 1 FROM sync_operations o WHERE o.transactionId = t.id
                    AND o.entity IN ('file', 'meeting_attachment', 'recording')) AS attachment,
                EXISTS(SELECT 1 FROM sync_operations o WHERE o.transactionId = t.id
                    AND o.entity IN ('meeting', 'summary', 'transcript')) AS text
            FROM sync_transactions t WHERE t.workspace_id = ? AND t.connectionId = ? ORDER BY t.sequence LIMIT 1
            """, arguments: [workspace.id, connectionId])
            let problem = SyncProblem(json: head?["serverResponseJSON"])
            let blockedReason = (head?["blockedReason"] as String?).flatMap(SyncBlockedReason.init(rawValue:))
            var issues: [SyncProgressIssue] = []
            if let blockedReason, let head {
                let transactionId: UUID = head["id"]
                try issues.append(.init(
                    source: .queue(blockedReason),
                    status: problem?.status,
                    code: problem?.code ?? blockedReason.rawValue,
                    target: syncTarget(
                        problem: problem,
                        transactionId: transactionId,
                        workspaceId: workspace.id,
                        in: db
                    )
                ))
            }
            if let incident = SyncIncident(jsonString: workspace.syncPullErrorJSON) {
                issues.append(.init(
                    source: .pull,
                    status: incident.status,
                    code: incident.code,
                    target: .init(entity: .workspace, id: workspace.id)
                ))
            } else if workspace.syncRecoveryState == "updateRequired" {
                issues.append(.init(
                    source: .pull,
                    status: problem?.status ?? 426,
                    code: problem?.code ?? "sync_upgrade_required",
                    target: .init(entity: .workspace, id: workspace.id)
                ))
            }
            let archiveFailures = try SyncRecordingArchiveFailure.fetchAll(db, sql: """
            SELECT a.meetingId, m.name AS meetingName, max(a.failureCode) AS code
            FROM recording_archives a JOIN meetings m ON m.id = a.meetingId
            WHERE a.workspace_id = ? AND a.connectionId = ? AND a.state = 'failed'
            GROUP BY a.meetingId, m.name ORDER BY m.createdAt, a.meetingId
            """, arguments: [workspace.id, connectionId])
            let state = try fetchWorkspaceSyncState(workspace, in: db)
            let phase: WorkspaceSyncProgress.Phase
            switch state {
            case .blocked, .updateRequired, .relocationPaused:
                phase = .attention
            case .synced where issues.isEmpty && archiveFailures.isEmpty:
                phase = .synced
            default:
                if !issues.isEmpty || !archiveFailures.isEmpty {
                    phase = .attention
                } else if workspace.syncConfirmedConnectionId != connectionId {
                    phase = .preparing
                } else if let head {
                    let response: String? = head["serverResponseJSON"]
                    let lease: Date? = head["leaseExpiresAt"]
                    if response != nil, lease == nil {
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
            let impact: SyncDiscardImpact? = if let blockedReason,
                                                blockedReason == .conflict || blockedReason == .validation {
                try head.map { row in
                    try discardImpact(
                        workspaceId: workspace.id,
                        fromSequence: row["sequence"],
                        reason: blockedReason,
                        in: db
                    )
                }
            } else {
                nil
            }
            let progress = WorkspaceSyncProgress(
                id: workspace.id,
                name: workspace.name,
                state: state,
                phase: phase,
                issues: issues,
                allowsCanonicalEdits: workspace.allowsCanonicalEdits,
                retryAt: head?["availableAt"],
                retryErrorCode: phase == .retrying ? problem?.code : nil,
                discardImpact: impact,
                recordingArchiveFailures: archiveFailures,
                meetings: remaining["meeting", default: 0],
                files: remaining["file", default: 0],
                attachments: remaining["meeting_attachment", default: 0],
                other: remaining["other", default: 0]
            )
            let existing = accounts[connectionId] ?? AccountSyncProgress(workspaces: [])
            accounts[connectionId] = .init(discoveryIssue: existing.discoveryIssue, workspaces: existing.workspaces + [progress])
        }
        return accounts
    }

    private nonisolated static func discardImpact(
        workspaceId: UUID,
        fromSequence sequence: Int64,
        reason: SyncBlockedReason,
        in db: Database
    ) throws -> SyncDiscardImpact {
        let queue = try Row.fetchOne(db, sql: """
        SELECT count(DISTINCT t.id) AS transactions, count(o.id) AS operations,
            count(DISTINCT o.entity || ':' || hex(o.entityId)) AS records,
            (SELECT latest.id FROM sync_transactions latest
             WHERE latest.workspace_id = ? AND latest.sequence >= ?
             ORDER BY latest.sequence DESC LIMIT 1) AS lastTransactionId
        FROM sync_transactions t LEFT JOIN sync_operations o ON o.transactionId = t.id
        WHERE t.workspace_id = ? AND t.sequence >= ?
        """, arguments: [workspaceId, sequence, workspaceId, sequence])
        let hasConfirmedWorkspace = try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM sync_entity_state WHERE workspace_id = ? AND entity = 'workspace' AND entityId = ?)",
            arguments: [workspaceId, workspaceId]
        ) ?? false
        let rebuildInitialSnapshot = reason == .validation && !hasConfirmedWorkspace
        let released: Row? = if !rebuildInitialSnapshot {
            try Row.fetchOne(db, sql: """
            WITH abandoned AS (
                SELECT DISTINCT c.entity, c.entityId FROM sync_content_state c
                JOIN sync_operations o ON o.entity = c.entity AND o.entityId = c.entityId
                JOIN sync_transactions t ON t.id = o.transactionId AND t.workspace_id = c.workspace_id
                WHERE c.workspace_id = ? AND t.sequence >= ?
            )
            SELECT count(DISTINCT a.entity || ':' || hex(a.entityId)) AS bodies,
                count(DISTINCT CASE
                    WHEN a.entity IN ('summary', 'transcript') THEN a.entityId
                    WHEN a.entity = 'file' THEN ma.meetingId END) AS meetings
            FROM abandoned a LEFT JOIN meeting_attachments ma ON a.entity = 'file' AND ma.fileId = a.entityId
            """, arguments: [workspaceId, sequence])
        } else {
            nil
        }
        let transactions: Int = queue?["transactions"] ?? 0
        let operations: Int = queue?["operations"] ?? 0
        let records: Int = queue?["records"] ?? 0
        let localBodies: Int = released?["bodies"] ?? 0
        let meetings: Int = released?["meetings"] ?? 0
        guard let lastTransactionId: UUID = queue?["lastTransactionId"] else { throw TextContentError.changed }
        return .init(
            transactions: transactions,
            operations: operations,
            records: records,
            localBodies: localBodies,
            meetings: meetings,
            lastTransactionId: lastTransactionId,
            hasConfirmedWorkspace: hasConfirmedWorkspace
        )
    }

    private nonisolated static func syncTarget(
        problem: SyncProblem?,
        transactionId: UUID,
        workspaceId: UUID,
        in db: Database
    ) throws -> SyncRecordTarget {
        if let operationId = problem?.operationId,
           let row = try Row.fetchOne(
               db,
               sql: "SELECT entity, entityId FROM sync_operations WHERE id = ? AND transactionId = ?",
               arguments: [operationId, transactionId]
           ), let target = try normalizedTarget(entity: row["entity"], id: row["entityId"], in: db) {
            return target
        }
        if let conflict = problem?.conflicts?.first,
           let target = try normalizedTarget(entity: conflict.entity, id: conflict.id, in: db) {
            return target
        }
        return .init(entity: .workspace, id: workspaceId)
    }

    private nonisolated static func normalizedTarget(
        entity: SyncEntity,
        id: UUID,
        in db: Database
    ) throws -> SyncRecordTarget? {
        switch entity {
        case .summary, .transcript, .meeting:
            .init(entity: .meeting, id: id)
        case .meetingAttachment:
            try MeetingAttachmentRecord.fetchOne(db, key: id).map { .init(entity: .file, id: $0.fileId) }
        case .recording:
            try RecordingArchiveRecord.fetchOne(db, key: id).map { .init(entity: .meeting, id: $0.meetingId) }
        case .workspace, .project, .file:
            .init(entity: entity, id: id)
        case .meetingEvent:
            nil
        }
    }
}

private struct SyncProblem: Decodable {
    struct Conflict: Decodable {
        let entity: SyncEntity
        let id: UUID
    }

    let status: Int?
    let code: String?
    let operationId: UUID?
    let conflicts: [Conflict]?

    init?(json: String?) {
        guard let json, let value = try? SyncJSON.decoder.decode(Self.self, from: Data(json.utf8)) else { return nil }
        self = value
    }
}
