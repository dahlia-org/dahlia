import CryptoKit
import DahliaRuntimeSupport
import Foundation
import GRDB

enum SyncEntity: String, Codable, DatabaseValueConvertible, Sendable {
    case vault
    case project
    case meeting
    case summary
    case transcript
    case screenshot
}

enum SyncAction: String, Codable, DatabaseValueConvertible, Sendable {
    case create
    case update
    case delete
    case upsert
    case patch
    case reset
}

enum SyncBlockedReason: String, DatabaseValueConvertible, Sendable {
    case validation
    case conflict
    case authorization
}

struct SyncOperationDraft: Sendable {
    let id: UUID
    let entity: SyncEntity
    let action: SyncAction
    let entityId: UUID
    let payloadJSON: Data?

    init(
        id: UUID = .v7(),
        entity: SyncEntity,
        action: SyncAction,
        entityId: UUID,
        payloadJSON: Data? = nil
    ) {
        self.id = id
        self.entity = entity
        self.action = action
        self.entityId = entityId
        self.payloadJSON = payloadJSON
    }

}

struct SyncTranscriptPatchSegment: Sendable {
    let segmentId: UUID
    let startTime: Date
    let endTime: Date?
    let text: String
    let isConfirmed: Bool
    let audioSource: String?
    let speakerLabel: String?

    init(_ record: TranscriptSegmentRecord) {
        segmentId = record.id
        startTime = record.startTime
        endTime = record.endTime
        text = record.text
        isConfirmed = record.isConfirmed
        audioSource = record.audioSource
        speakerLabel = record.speakerLabel
    }
}

struct SyncScreenshotAttachment: Sendable {
    let mimeType: String
    let sha256: String
    let bytes: Data

    init(mimeType: String, bytes: Data) {
        self.mimeType = mimeType
        self.bytes = bytes
        sha256 = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

struct SyncTranscriptPatchSnapshot: Sendable {
    let segments: [SyncTranscriptPatchSegment]
    let deletions: [UUID]
}

struct SyncQueuedOperation: Sendable {
    let id: UUID
    let entity: SyncEntity
    let action: SyncAction
    let entityId: UUID
    let baseRevision: Int?
    let payloadJSON: Data?
}

struct SyncQueuedTransaction: Sendable {
    let sequence: Int64
    let id: UUID
    let vaultId: UUID
    let connectionId: UUID
    let createdAt: Date
    let attempts: Int
    let operations: [SyncQueuedOperation]
}

struct SyncTransactionResponse: Decodable, Sendable {
    struct Record: Decodable, Sendable {
        let entity: SyncEntity
        let id: UUID
        let revision: Int?
        let record: JSONValue?
    }

    let id: UUID
    let status: String
    let cursor: String
    let records: [Record]
}

struct SyncCanonicalPayload: Decodable, Sendable {
    let parentProjectId: UUID?
    let projectId: UUID?
    let meetingId: UUID?
    let name: String?
    let description: String?
    let projectType: String?
    let status: String?
    let duration: Double?
    let recordingStartedAt: Date?
    let createdAt: Date?
    let updatedAt: Date?
    let title: String?
    let document: String?
    let capturedAt: Date?
    let contentType: String?
    let contentHash: String?
    let ocrText: String?
    let caption: String?
}

enum SyncJSON {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: value) { return date }
            throw try DecodingError.dataCorruptedError(
                in: decoder.singleValueContainer(),
                debugDescription: "Invalid ISO-8601 date"
            )
        }
        return decoder
    }()
}

enum SyncTransactionRecorder {
    private static let maximumOperationsPerTransaction = 1000
    private static let maximumPayloadBytesPerTransaction = 6 * 1024 * 1024

    static func recordBatches(
        vaultId: UUID,
        operations: [SyncOperationDraft],
        allowAfterReset: Bool = false,
        connectionIdOverride: UUID? = nil,
        in db: Database
    ) throws {
        var batch: [SyncOperationDraft] = []
        var payloadBytes = 0
        for operation in operations {
            let operationBytes = (operation.payloadJSON?.count ?? 0) + 256
            if !batch.isEmpty,
               payloadBytes + operationBytes > maximumPayloadBytesPerTransaction
               || batch.count == maximumOperationsPerTransaction {
                try record(
                    vaultId: vaultId,
                    operations: batch,
                    allowAfterReset: allowAfterReset,
                    connectionIdOverride: connectionIdOverride,
                    in: db
                )
                batch.removeAll(keepingCapacity: true)
                payloadBytes = 0
            }
            batch.append(operation)
            payloadBytes += operationBytes
        }
        if !batch.isEmpty {
            try record(
                vaultId: vaultId,
                operations: batch,
                allowAfterReset: allowAfterReset,
                connectionIdOverride: connectionIdOverride,
                in: db
            )
        }
    }

    /// Records an immutable domain transaction. A Vault without a confirmed remote target stays local-only.
    @discardableResult
    static func record(
        vaultId: UUID,
        operations requestedOperations: [SyncOperationDraft],
        transcriptSegments: [UUID: [SyncTranscriptPatchSegment]] = [:],
        transcriptDeletions: [UUID: [UUID]] = [:],
        screenshotAttachments: [UUID: SyncScreenshotAttachment] = [:],
        allowAfterReset: Bool = false,
        connectionIdOverride: UUID? = nil,
        in db: Database
    ) throws -> UUID? {
        let confirmedSegments = transcriptSegments.mapValues { $0.filter(\.isConfirmed) }
        let operations = requestedOperations.filter { operation in
            operation.entity != .transcript || operation.action != .patch
                || !confirmedSegments[operation.id, default: []].isEmpty
                || !transcriptDeletions[operation.id, default: []].isEmpty
        }
        guard !operations.isEmpty else { return nil }
        guard Set(operations.map { "\($0.entity.rawValue):\($0.entityId.uuidString)" }).count == operations.count else {
            throw DatabaseError(message: "duplicate sync entity in transaction")
        }
        guard let vault = try VaultRecord.fetchOne(db, key: vaultId),
              let targetConnectionId = vault.accountConnectionId else { return nil }
        let connectionId: UUID
        if let connectionIdOverride {
            guard connectionIdOverride == targetConnectionId,
                  vault.syncConfirmedConnectionId == nil else { return nil }
            connectionId = connectionIdOverride
        } else {
            guard let confirmedConnectionId = vault.syncConfirmedConnectionId,
                  confirmedConnectionId == targetConnectionId else {
                // A local mutation invalidates a bounded initial snapshot before it can be sent.
                try SyncTransactionQueue.discardPartialSnapshot(vaultId: vaultId, in: db)
                return nil
            }
            connectionId = confirmedConnectionId
        }
        guard vault.syncRole != "member" else { throw SyncTransactionQueueError.readOnlyVault }
        if !allowAfterReset {
            let resetIsLast = try Bool.fetchOne(
                db,
                sql: """
                SELECT EXISTS (
                    SELECT 1 FROM sync_operations reset_operation
                    JOIN sync_transactions reset_transaction
                      ON reset_transaction.id = reset_operation.transactionId
                    WHERE reset_transaction.vaultId = ?
                      AND reset_operation.entity = 'vault'
                      AND reset_operation.action = 'reset'
                      AND NOT EXISTS (
                        SELECT 1 FROM sync_transactions later
                        WHERE later.vaultId = reset_transaction.vaultId
                          AND later.sequence > reset_transaction.sequence
                      )
                )
                """,
                arguments: [vaultId]
            ) ?? false
            if resetIsLast { return nil }
        }

        let transactionId = UUID.v7()
        let now = Date()
        try db.execute(
            sql: """
            INSERT INTO sync_transactions(id, vaultId, connectionId, createdAt, availableAt)
            VALUES (?, ?, ?, ?, ?)
            """,
            arguments: [transactionId, vaultId, connectionId, now, now]
        )

        for (position, operation) in operations.enumerated() {
            let attachment = screenshotAttachments[operation.id]
            let usesScreenshotRow = if attachment == nil {
                false
            } else {
                try Bool.fetchOne(
                    db,
                    sql: "SELECT EXISTS (SELECT 1 FROM screenshots WHERE id = ?)",
                    arguments: [operation.entityId]
                ) ?? false
            }
            let attachmentBytes: Data? = if !usesScreenshotRow {
                attachment?.bytes
            } else {
                nil
            }
            let confirmedRevision = try Int.fetchOne(
                db,
                sql: """
                SELECT confirmedRevision FROM sync_entity_state
                WHERE vaultId = ? AND entity = ? AND entityId = ?
                """,
                arguments: [vaultId, operation.entity, operation.entityId]
            )
            let preceding = try Row.fetchOne(
                db,
                sql: """
                SELECT o.action, o.baseRevision FROM sync_operations o
                JOIN sync_transactions t ON t.id = o.transactionId
                WHERE t.vaultId = ? AND o.entity = ? AND o.entityId = ?
                ORDER BY t.sequence DESC, o.position DESC LIMIT 1
                """,
                arguments: [vaultId, operation.entity, operation.entityId]
            )
            let precedingAction = (preceding?["action"] as String?).flatMap(SyncAction.init(rawValue:))
            let precedingBase: Int? = preceding?["baseRevision"]
            let precedingExpected = precedingAction.map { $0 == .create ? 1 : (precedingBase ?? 0) + 1 }
            let baseRevision: Int? = if operation.action == .create {
                nil
            } else if let precedingExpected {
                precedingExpected
            } else if let confirmedRevision {
                confirmedRevision
            } else if operation.entity == .summary || operation.entity == .transcript {
                0
            } else {
                nil
            }

            try db.execute(
                sql: """
                INSERT INTO sync_operations(
                    transactionId, position, id, entity, action, entityId,
                    baseRevision, payloadJSON, attachmentMimeType, attachmentSHA256, attachmentBytes
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    transactionId, position, operation.id, operation.entity, operation.action,
                    operation.entityId, baseRevision,
                    operation.payloadJSON.map { String(decoding: $0, as: UTF8.self) },
                    attachment?.mimeType,
                    attachment?.sha256,
                    attachmentBytes,
                ]
            )
            var patchPosition = 0
            for segment in confirmedSegments[operation.id, default: []] {
                try db.execute(
                    sql: """
                    INSERT INTO sync_transcript_patch_items(
                        operationId, position, action, segmentId, startTime, endTime, text,
                        isConfirmed, audioSource, speakerLabel
                    ) VALUES (?, ?, 'upsert', ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        operation.id, patchPosition, segment.segmentId, segment.startTime, segment.endTime,
                        segment.text, segment.isConfirmed, segment.audioSource, segment.speakerLabel,
                    ]
                )
                patchPosition += 1
            }
            for segmentId in transcriptDeletions[operation.id, default: []] {
                try db.execute(
                    sql: """
                    INSERT INTO sync_transcript_patch_items(operationId, position, action, segmentId)
                    VALUES (?, ?, 'delete', ?)
                    """,
                    arguments: [operation.id, patchPosition, segmentId]
                )
                patchPosition += 1
            }
        }
        return transactionId
    }
}

enum SyncTransactionQueue {
    static let leaseDuration: TimeInterval = 120

    static func discardPartialSnapshot(vaultId: UUID, in db: Database) throws {
        let resetSequence = try Int64.fetchOne(
            db,
            sql: """
            SELECT t.sequence FROM sync_transactions t
            JOIN sync_operations o ON o.transactionId = t.id
            WHERE t.vaultId = ? AND o.entity = 'vault' AND o.action = 'reset'
            ORDER BY t.sequence LIMIT 1
            """,
            arguments: [vaultId]
        )
        if let resetSequence {
            try db.execute(
                sql: "DELETE FROM sync_transactions WHERE vaultId = ? AND sequence > ?",
                arguments: [vaultId, resetSequence]
            )
        } else {
            try db.execute(sql: "DELETE FROM sync_transactions WHERE vaultId = ?", arguments: [vaultId])
        }
    }

    static func claim(dbQueue: DatabaseQueue) async throws -> SyncQueuedTransaction? {
        try await dbQueue.write { db in
            let now = Date()
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT t.sequence, t.id, t.vaultId, t.connectionId, t.createdAt, t.attempts
                FROM sync_transactions t
                JOIN vaults v ON v.id = t.vaultId
                WHERE v.accountConnectionId = t.connectionId
                  AND v.syncConfirmedConnectionId = t.connectionId
                  AND NOT EXISTS (
                    SELECT 1 FROM sync_entity_state s
                    WHERE s.vaultId = t.vaultId AND s.entity = 'vault' AND s.entityId = t.vaultId
                      AND s.confirmedRevision IS NULL
                  )
                  AND t.blockedReason IS NULL
                  AND t.availableAt <= ?
                  AND (t.leaseExpiresAt IS NULL OR t.leaseExpiresAt < ?)
                  AND NOT EXISTS (
                    SELECT 1 FROM sync_transactions earlier
                    WHERE earlier.vaultId = t.vaultId AND earlier.sequence < t.sequence
                  )
                ORDER BY t.sequence
                LIMIT 1
                """,
                arguments: [now, now]
            ) else { return nil }
            let transactionId: UUID = row["id"]
            let operations = try Row.fetchAll(
                db,
                sql: """
                SELECT id, entity, action, entityId, baseRevision, payloadJSON
                FROM sync_operations WHERE transactionId = ? ORDER BY position
                """,
                arguments: [transactionId]
            ).map { operation in
                SyncQueuedOperation(
                    id: operation["id"],
                    entity: operation["entity"],
                    action: operation["action"],
                    entityId: operation["entityId"],
                    baseRevision: operation["baseRevision"],
                    payloadJSON: (operation["payloadJSON"] as String?).map { Data($0.utf8) }
                )
            }
            try db.execute(
                sql: """
                UPDATE sync_transactions SET attempts = attempts + 1,
                    leaseExpiresAt = ? WHERE id = ?
                """,
                arguments: [now.addingTimeInterval(leaseDuration), transactionId]
            )
            return SyncQueuedTransaction(
                sequence: row["sequence"],
                id: transactionId,
                vaultId: row["vaultId"],
                connectionId: row["connectionId"],
                createdAt: row["createdAt"],
                attempts: (row["attempts"] as Int) + 1,
                operations: operations
            )
        }
    }

    static func retry(_ transaction: SyncQueuedTransaction, code: String, dbQueue: DatabaseQueue) async throws {
        let delay = min(pow(2, Double(min(transaction.attempts, 8))), 300)
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE sync_transactions SET availableAt = ?, leaseExpiresAt = NULL,
                    blockedReason = NULL, serverResponseJSON = ? WHERE id = ?
                """,
                arguments: [Date().addingTimeInterval(delay), code, transaction.id]
            )
        }
    }

    static func block(
        _ transaction: SyncQueuedTransaction,
        reason: SyncBlockedReason,
        response: Data,
        dbQueue: DatabaseQueue
    ) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE sync_transactions SET blockedReason = ?, serverResponseJSON = ?,
                    leaseExpiresAt = NULL WHERE id = ?
                """,
                arguments: [reason, String(decoding: response, as: UTF8.self), transaction.id]
            )
        }
    }

    static func complete(
        _ transaction: SyncQueuedTransaction,
        response: SyncTransactionResponse,
        dbQueue: DatabaseQueue
    ) async throws {
        guard response.id == transaction.id, response.status == "committed" else {
            throw SyncTransactionQueueError.invalidReceipt
        }
        let operationKeys = Set(transaction.operations.map { "\($0.entity.rawValue):\($0.entityId.uuidString)" })
        let recordKeys = Set(response.records.map { "\($0.entity.rawValue):\($0.id.uuidString)" })
        guard response.records.count == transaction.operations.count, recordKeys == operationKeys else {
            throw SyncTransactionQueueError.invalidReceipt
        }
        try await dbQueue.write { db in
            guard try matchesExpectedConnection(
                vaultId: transaction.vaultId,
                connectionId: transaction.connectionId,
                in: db
            ) else { return }
            let transactionStillExists = try Bool.fetchOne(
                db,
                sql: """
                SELECT EXISTS (
                    SELECT 1 FROM sync_transactions
                    WHERE id = ? AND vaultId = ? AND connectionId = ?
                )
                """,
                arguments: [transaction.id, transaction.vaultId, transaction.connectionId]
            ) ?? false
            guard transactionStillExists else { return }
            let resetOperation = transaction.operations.contains {
                $0.entity == .vault && $0.action == .reset
            }
            let hasLaterTransaction = try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM sync_transactions WHERE vaultId = ? AND sequence > ?)",
                arguments: [transaction.vaultId, transaction.sequence]
            ) ?? false
            for record in response.records {
                let hasLaterOperation = try Bool.fetchOne(
                    db,
                    sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM sync_operations o
                        JOIN sync_transactions t ON t.id = o.transactionId
                        WHERE t.vaultId = ? AND t.sequence > ? AND o.entity = ? AND o.entityId = ?
                    )
                    """,
                    arguments: [transaction.vaultId, transaction.sequence, record.entity, record.id]
                ) ?? false
                if !hasLaterOperation, let value = record.record {
                    let canonical = try SyncJSON.decoder.decode(
                        SyncCanonicalPayload.self,
                        from: SyncJSON.encoder.encode(value)
                    )
                    try applyCanonical(record.entity, id: record.id, vaultId: transaction.vaultId, value: canonical, in: db)
                }
                try db.execute(
                    sql: """
                    INSERT INTO sync_entity_state(vaultId, entity, entityId, confirmedRevision)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(vaultId, entity, entityId) DO UPDATE SET
                        confirmedRevision = excluded.confirmedRevision
                    """,
                    arguments: [transaction.vaultId, record.entity, record.id, record.revision]
                )
                if record.entity == .vault,
                   transaction.operations.contains(where: { $0.entity == .vault && $0.action == .create }) {
                    try db.execute(
                        sql: "UPDATE vaults SET syncRole = 'owner' WHERE id = ? AND syncRole IS NULL",
                        arguments: [transaction.vaultId]
                    )
                }
            }
            try db.execute(
                sql: "UPDATE vaults SET syncLastCommittedCursor = ? WHERE id = ?",
                arguments: [response.cursor, transaction.vaultId]
            )
            if resetOperation {
                try db.execute(
                    sql: "UPDATE vaults SET syncPullCursor = ? WHERE id = ?",
                    arguments: [response.cursor, transaction.vaultId]
                )
            }
            try db.execute(sql: "DELETE FROM sync_transactions WHERE id = ?", arguments: [transaction.id])
            if resetOperation, !hasLaterTransaction {
                try db.execute(
                    sql: """
                    UPDATE vaults SET syncConfirmedConnectionId = NULL,
                        syncPullCursor = NULL, syncLastCommittedCursor = NULL
                    WHERE id = ?
                    """,
                    arguments: [transaction.vaultId]
                )
                try db.execute(
                    sql: "DELETE FROM sync_entity_state WHERE vaultId = ?",
                    arguments: [transaction.vaultId]
                )
            }
        }
    }

    static func applyCanonical(
        _ entity: SyncEntity,
        id: UUID,
        vaultId: UUID,
        value: SyncCanonicalPayload,
        in db: Database
    ) throws {
        switch entity {
        case .vault:
            if let name = value.name {
                try db.execute(sql: "UPDATE vaults SET name = ? WHERE id = ?", arguments: [name, vaultId])
            }
        case .project:
            guard let name = value.name, let createdAt = value.createdAt else { return }
            try ProjectRecord.applyCanonical(
                id: id,
                vaultId: vaultId,
                parentProjectId: value.parentProjectId,
                name: name,
                createdAt: createdAt,
                description: value.description ?? "",
                projectType: value.projectType.flatMap(ProjectType.init(rawValue:)),
                in: db
            )
        case .meeting:
            guard let name = value.name, let status = value.status,
                  let createdAt = value.createdAt, let updatedAt = value.updatedAt else { return }
            try db.execute(sql: """
            INSERT INTO meetings(
                id, vaultId, projectId, name, description, status, duration,
                createdAt, updatedAt, recordingStartedAt
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET projectId = excluded.projectId, name = excluded.name,
                description = excluded.description, status = excluded.status, duration = excluded.duration,
                createdAt = excluded.createdAt, updatedAt = excluded.updatedAt,
                recordingStartedAt = excluded.recordingStartedAt
            """, arguments: [
                id, vaultId, value.projectId, name, value.description ?? "", status,
                value.duration, createdAt, updatedAt, value.recordingStartedAt,
            ])
        case .summary:
            if let title = value.title, let document = value.document, let createdAt = value.createdAt {
                try SummaryRecord(meetingId: id, title: title, document: document, createdAt: createdAt).save(db)
            } else {
                try db.execute(sql: "DELETE FROM summaries WHERE meetingId = ?", arguments: [id])
            }
        case .screenshot:
            try db.execute(
                sql: "UPDATE screenshots SET capturedAt = coalesce(?, capturedAt), ocrText = ?, caption = ? WHERE id = ?",
                arguments: [value.capturedAt, value.ocrText, value.caption, id]
            )
        case .transcript:
            break
        }
    }

    static func hasPending(vaultId: UUID, in db: Database) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM sync_transactions WHERE vaultId = ?)",
            arguments: [vaultId]
        ) ?? false
    }

    static func hasPending(vaultId: UUID, dbQueue: DatabaseQueue) async throws -> Bool {
        try await dbQueue.read { db in
            try hasPending(vaultId: vaultId, in: db)
        }
    }

    static func reconcileRevisions(
        _ changes: [SyncChangePage.Change],
        vaultId: UUID,
        connectionId: UUID,
        dbQueue: DatabaseQueue
    ) async throws {
        try await dbQueue.write { db in
            guard try matchesExpectedConnection(vaultId: vaultId, connectionId: connectionId, in: db),
                  try Bool.fetchOne(
                      db,
                      sql: "SELECT EXISTS(SELECT 1 FROM sync_entity_state WHERE vaultId = ? AND entity = 'vault' AND entityId = ? AND confirmedRevision IS NULL)",
                      arguments: [vaultId, vaultId]
                  ) == true else { return }
            guard changes.contains(where: {
                $0.entity == .vault && $0.entityId == vaultId && $0.record != nil && $0.revision != nil
            }) else { throw SyncTransactionQueueError.invalidReceipt }

            // These revisions permit queued edits to resume; the cursor stays nil until canonical data is applied.
            var revisions: [String: Int] = [:]
            for change in changes {
                try db.execute(
                    sql: """
                    INSERT INTO sync_entity_state(vaultId, entity, entityId, confirmedRevision)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(vaultId, entity, entityId) DO UPDATE SET confirmedRevision = excluded.confirmedRevision
                    """,
                    arguments: [vaultId, change.entity, change.entityId, change.revision]
                )
                if let revision = change.revision {
                    revisions["\(change.entity.rawValue):\(change.entityId)"] = revision
                }
            }
            let operations = try Row.fetchAll(
                db,
                sql: """
                SELECT o.id, o.entity, o.entityId, o.action, o.baseRevision, t.attempts FROM sync_operations o
                JOIN sync_transactions t ON t.id = o.transactionId
                WHERE t.vaultId = ? ORDER BY t.sequence, o.position
                """,
                arguments: [vaultId]
            )
            for operation in operations {
                let id: UUID = operation["id"]
                let entity: SyncEntity = operation["entity"]
                let entityId: UUID = operation["entityId"]
                let action: SyncAction = operation["action"]
                let key = "\(entity.rawValue):\(entityId)"
                let baseRevision: Int? = if operation["attempts"] as Int > 0 {
                    // A pre-upgrade attempt may already have committed; retain its idempotent request body.
                    operation["baseRevision"]
                } else if action == .create {
                    nil
                } else if let revision = revisions[key] {
                    revision
                } else if entity == .transcript || entity == .summary {
                    0
                } else {
                    nil
                }
                try db.execute(
                    sql: "UPDATE sync_operations SET baseRevision = ? WHERE id = ?",
                    arguments: [baseRevision, id]
                )
                revisions[key] = action == .create ? 1 : (baseRevision ?? 0) + 1
            }
        }
    }

    static func matchesExpectedConnection(vaultId: UUID, connectionId: UUID, in db: Database) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: """
            SELECT EXISTS (
                SELECT 1 FROM vaults
                WHERE id = ? AND accountConnectionId = ? AND syncConfirmedConnectionId = ?
            )
            """,
            arguments: [vaultId, connectionId, connectionId]
        ) ?? false
    }

    static func isConfirmed(
        vaultId: UUID,
        entity: SyncEntity,
        entityId: UUID,
        revision: Int?,
        dbQueue: DatabaseQueue
    ) async throws -> Bool {
        try await dbQueue.read { db in
            try Bool.fetchOne(
                db,
                sql: """
                SELECT EXISTS (
                    SELECT 1 FROM sync_entity_state
                    WHERE vaultId = ? AND entity = ? AND entityId = ?
                      AND confirmedRevision IS ?
                )
                """,
                arguments: [vaultId, entity, entityId, revision]
            ) ?? false
        }
    }

    static func transcriptPatch(operationId: UUID, dbQueue: DatabaseQueue) async throws -> SyncTranscriptPatchSnapshot {
        try await dbQueue.read { db in
            try loadPatch(operationId: operationId, in: db)
        }
    }

    static func screenshotAttachment(operationId: UUID, dbQueue: DatabaseQueue) async throws -> SyncScreenshotAttachment? {
        try await dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT operation.attachmentMimeType AS mimeType,
                    operation.attachmentSHA256 AS sha256,
                    COALESCE(operation.attachmentBytes, screenshot.imageData) AS bytes
                FROM sync_operations operation
                LEFT JOIN screenshots screenshot ON screenshot.id = operation.entityId
                WHERE operation.id = ?
                  AND operation.attachmentMimeType IS NOT NULL
                  AND COALESCE(operation.attachmentBytes, screenshot.imageData) IS NOT NULL
                """,
                arguments: [operationId]
            ) else { return nil }
            return SyncScreenshotAttachment(
                mimeType: row["mimeType"],
                sha256: row["sha256"],
                bytes: row["bytes"]
            )
        }
    }

    static func discard(vaultId: UUID, fromSequence: Int64 = 0, in db: Database) throws {
        try db.execute(
            sql: "DELETE FROM sync_transactions WHERE vaultId = ? AND sequence >= ?",
            arguments: [vaultId, fromSequence]
        )
    }

    static func acceptServerVersion(vaultId: UUID, dbQueue: DatabaseQueue) async throws {
        _ = try await discardBlocked(vaultId: vaultId, reason: .conflict, dbQueue: dbQueue)
    }

    static func discardInvalidTransaction(vaultId: UUID, dbQueue: DatabaseQueue) async throws {
        if try await discardBlocked(vaultId: vaultId, reason: .validation, dbQueue: dbQueue) {
            try await SyncInitialSnapshotBuilder.enqueuePending(dbQueue: dbQueue)
        }
    }

    static func retryInvalidTransaction(vaultId: UUID, dbQueue: DatabaseQueue) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE sync_transactions SET blockedReason = NULL, serverResponseJSON = NULL,
                    availableAt = ?, leaseExpiresAt = NULL
                WHERE vaultId = ? AND blockedReason = 'validation'
                """,
                arguments: [Date(), vaultId]
            )
        }
    }

    static func retryAuthorizationBlocks(connectionId: UUID, dbQueue: DatabaseQueue) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE sync_transactions SET blockedReason = NULL, serverResponseJSON = NULL,
                    availableAt = ?, leaseExpiresAt = NULL
                WHERE connectionId = ? AND blockedReason = 'authorization'
                """,
                arguments: [Date(), connectionId]
            )
        }
    }

    private static func discardBlocked(
        vaultId: UUID,
        reason: SyncBlockedReason,
        dbQueue: DatabaseQueue
    ) async throws -> Bool {
        try await dbQueue.write { db in
            guard let blocked = try Row.fetchOne(
                db,
                sql: """
                SELECT sequence FROM sync_transactions
                WHERE vaultId = ? AND blockedReason = ? ORDER BY sequence LIMIT 1
                """,
                arguments: [vaultId, reason]
            ) else { return false }
            let hasConfirmedVault = try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM sync_entity_state WHERE vaultId = ? AND entity = 'vault' AND entityId = ?)",
                arguments: [vaultId, vaultId]
            ) ?? false
            let rebuildInitialSnapshot = reason == .validation && !hasConfirmedVault
            let sequence: Int64 = blocked["sequence"]
            try discard(vaultId: vaultId, fromSequence: sequence, in: db)
            try db.execute(sql: "DELETE FROM sync_entity_state WHERE vaultId = ?", arguments: [vaultId])
            if !rebuildInitialSnapshot {
                // Keep the pull target distinct from an interrupted initial upload until reconciliation completes.
                try db.execute(
                    sql: "INSERT INTO sync_entity_state(vaultId, entity, entityId, confirmedRevision) VALUES (?, 'vault', ?, NULL)",
                    arguments: [vaultId, vaultId]
                )
            }
            try db.execute(
                sql: """
                UPDATE vaults SET
                    syncConfirmedConnectionId = CASE WHEN ? THEN NULL ELSE syncConfirmedConnectionId END,
                    syncPullCursor = NULL
                WHERE id = ?
                """,
                arguments: [rebuildInitialSnapshot, vaultId]
            )
            return rebuildInitialSnapshot
        }
    }

    static func reapplyLocalVersion(vaultId: UUID, dbQueue: DatabaseQueue) async throws {
        let rebuildVault = try await dbQueue.write { db -> Bool in
            guard let first = try Row.fetchOne(
                db,
                sql: """
                SELECT sequence, serverResponseJSON FROM sync_transactions
                WHERE vaultId = ? AND blockedReason = 'conflict' ORDER BY sequence LIMIT 1
                """,
                arguments: [vaultId]
            ) else { return false }
            let sequence: Int64 = first["sequence"]
            let response: String? = first["serverResponseJSON"]
            let directMissingEntities = missingConflictEntities(response)
            let existingEntities = existingConflictEntities(response)
            if directMissingEntities.contains(.init(entity: .vault, id: vaultId)) {
                try discard(vaultId: vaultId, in: db)
                try db.execute(sql: "DELETE FROM sync_entity_state WHERE vaultId = ?", arguments: [vaultId])
                try db.execute(
                    sql: """
                    UPDATE vaults SET syncConfirmedConnectionId = NULL,
                        syncPullCursor = NULL, syncLastCommittedCursor = NULL
                    WHERE id = ?
                    """,
                    arguments: [vaultId]
                )
                return true
            }
            let missingProjects = Set(directMissingEntities.filter { $0.entity == .project })
            let missingMeetings = Set(directMissingEntities.compactMap { conflict in
                switch conflict.entity {
                case .meeting, .summary, .transcript:
                    MissingConflictEntity(entity: .meeting, id: conflict.id)
                default:
                    nil
                }
            })
            let missingEntities = directMissingEntities.union(missingMeetings)
            for missing in missingEntities {
                try db.execute(
                    sql: "DELETE FROM sync_entity_state WHERE vaultId = ? AND entity = ? AND entityId = ?",
                    arguments: [vaultId, missing.entity, missing.id]
                )
            }
            applyConflictRevision(response, vaultId: vaultId, in: db)
            let transactionIds = try UUID.fetchAll(
                db,
                sql: "SELECT id FROM sync_transactions WHERE vaultId = ? AND sequence >= ? ORDER BY sequence",
                arguments: [vaultId, sequence]
            )
            var queued: [RequeuedTransaction] = []
            let projectOperations = try missingProjectOperations(missingProjects, in: db)
            if !projectOperations.isEmpty {
                queued.append(.init(operations: projectOperations, segments: [:], deletions: [:], attachments: [:]))
            }
            var restoredMeetings = Set<UUID>()
            let meetingOperations = try missingMeetings.compactMap { missing -> SyncOperationDraft? in
                guard let meeting = try MeetingRecord.fetchOne(db, key: missing.id) else { return nil }
                restoredMeetings.insert(missing.id)
                return try SyncInitialSnapshotBuilder.meetingOperation(meeting, action: .create)
            }
            if !meetingOperations.isEmpty {
                queued.append(.init(operations: meetingOperations, segments: [:], deletions: [:], attachments: [:]))
            }
            for transactionId in transactionIds {
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT id, entity, action, entityId, payloadJSON,
                        attachmentMimeType, attachmentSHA256, attachmentBytes
                    FROM sync_operations WHERE transactionId = ? ORDER BY position
                    """,
                    arguments: [transactionId]
                )
                var operations: [SyncOperationDraft] = []
                var segments: [UUID: [SyncTranscriptPatchSegment]] = [:]
                var deletions: [UUID: [UUID]] = [:]
                var attachments: [UUID: SyncScreenshotAttachment] = [:]
                for row in rows {
                    let oldOperationId: UUID = row["id"]
                    let entity: SyncEntity = row["entity"]
                    let action: SyncAction = row["action"]
                    let entityId: UUID = row["entityId"]
                    let key = MissingConflictEntity(entity: entity, id: entityId)
                    if missingProjects.contains(key) { continue }
                    if missingMeetings.contains(key) { continue }
                    if directMissingEntities.contains(key),
                       entity == .summary || entity == .transcript,
                       !restoredMeetings.contains(entityId) { continue }
                    let missing = missingEntities.contains(key)
                    if missing, action == .delete { continue }
                    let rebasedAction = rebasedAction(
                        action,
                        missing: missing,
                        conflictsWithExisting: existingEntities.contains(key)
                    )
                    var payload = (row["payloadJSON"] as String?).map { Data($0.utf8) }
                    var replacementAttachment: SyncScreenshotAttachment?
                    if missing, entity == .screenshot, action != .delete {
                        guard let screenshot = try MeetingScreenshotRecord.fetchOne(db, key: entityId) else { continue }
                        let attachment = SyncScreenshotAttachment(
                            mimeType: screenshot.mimeType,
                            bytes: screenshot.imageData
                        )
                        payload = try SyncInitialSnapshotBuilder.screenshotOperation(
                            screenshot,
                            action: .upsert,
                            contentHash: attachment.sha256
                        ).payloadJSON
                        replacementAttachment = attachment
                    }
                    let operation = try SyncOperationDraft(
                        entity: entity,
                        action: rebasedAction,
                        entityId: entityId,
                        payloadJSON: rebasedAction == action ? payload : rebasedPayload(
                            from: payload, for: rebasedAction, entity: entity, entityId: entityId, in: db
                        )
                    )
                    operations.append(operation)
                    let patch = try loadPatch(operationId: oldOperationId, in: db)
                    segments[operation.id] = patch.segments
                    deletions[operation.id] = patch.deletions
                    if let replacementAttachment {
                        attachments[operation.id] = replacementAttachment
                    } else if let mime: String = row["attachmentMimeType"],
                              let sha: String = row["attachmentSHA256"],
                              let bytes: Data = row["attachmentBytes"] {
                        attachments[operation.id] = SyncScreenshotAttachment(mimeType: mime, sha256: sha, bytes: bytes)
                    }
                }
                if !operations.isEmpty {
                    queued.append(.init(
                        operations: operations,
                        segments: segments,
                        deletions: deletions,
                        attachments: attachments
                    ))
                }
            }
            try discard(vaultId: vaultId, fromSequence: sequence, in: db)
            for transaction in queued {
                try SyncTransactionRecorder.record(
                    vaultId: vaultId,
                    operations: transaction.operations,
                    transcriptSegments: transaction.segments,
                    transcriptDeletions: transaction.deletions,
                    screenshotAttachments: transaction.attachments,
                    in: db
                )
            }
            return false
        }
        if rebuildVault {
            try await SyncInitialSnapshotBuilder.enqueuePending(dbQueue: dbQueue)
        }
    }

    private static func missingProjectOperations(
        _ missingProjects: Set<MissingConflictEntity>,
        in db: Database
    ) throws -> [SyncOperationDraft] {
        try missingProjects.compactMap { missing -> (ProjectRecord, SyncOperationDraft)? in
            guard let project = try ProjectRecord.fetchOne(db, key: missing.id) else { return nil }
            return try (project, SyncInitialSnapshotBuilder.projectOperation(project, action: .create))
        }.sorted { left, right in
            if (left.0.parentProjectId == nil) != (right.0.parentProjectId == nil) {
                return left.0.parentProjectId == nil
            }
            return left.0.id.uuidString < right.0.id.uuidString
        }.map(\.1)
    }

    private static func loadPatch(operationId: UUID, in db: Database) throws -> SyncTranscriptPatchSnapshot {
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT * FROM sync_transcript_patch_items WHERE operationId = ? ORDER BY position",
            arguments: [operationId]
        )
        var segments: [SyncTranscriptPatchSegment] = []
        var deletions: [UUID] = []
        for row in rows {
            if row["action"] as String == "delete" {
                deletions.append(row["segmentId"])
            } else {
                segments.append(.init(
                    segmentId: row["segmentId"],
                    startTime: row["startTime"],
                    endTime: row["endTime"],
                    text: row["text"],
                    isConfirmed: row["isConfirmed"],
                    audioSource: row["audioSource"],
                    speakerLabel: row["speakerLabel"]
                ))
            }
        }
        return .init(segments: segments, deletions: deletions)
    }

    private static func applyConflictRevision(_ response: String?, vaultId: UUID, in db: Database) {
        guard let response, let data = response.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let conflicts = object["conflicts"] as? [[String: Any]] else { return }
        for conflict in conflicts {
            guard let entity = conflict["entity"] as? String,
                  let id = (conflict["id"] as? String).flatMap(UUID.init(uuidString:)) else { continue }
            let revision = conflict["serverRevision"] as? Int
            try? db.execute(
                sql: """
                INSERT INTO sync_entity_state(vaultId, entity, entityId, confirmedRevision)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(vaultId, entity, entityId) DO UPDATE SET confirmedRevision = excluded.confirmedRevision
                """,
                arguments: [vaultId, entity, id, revision]
            )
        }
    }

    private static func missingConflictEntities(_ response: String?) -> Set<MissingConflictEntity> {
        guard let response, let data = response.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let conflicts = object["conflicts"] as? [[String: Any]] else { return [] }
        return Set(conflicts.compactMap { conflict in
            guard conflict["serverRevision"] is NSNull,
                  let rawEntity = conflict["entity"] as? String,
                  let entity = SyncEntity(rawValue: rawEntity),
                  let rawID = conflict["id"] as? String,
                  let id = UUID(uuidString: rawID) else { return nil }
            return MissingConflictEntity(entity: entity, id: id)
        })
    }

    private static func existingConflictEntities(_ response: String?) -> Set<MissingConflictEntity> {
        guard let response, let data = response.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let conflicts = object["conflicts"] as? [[String: Any]] else { return [] }
        return Set(conflicts.compactMap { conflict in
            guard conflict["serverRevision"] is Int,
                  let rawEntity = conflict["entity"] as? String,
                  let entity = SyncEntity(rawValue: rawEntity),
                  let rawID = conflict["id"] as? String,
                  let id = UUID(uuidString: rawID) else { return nil }
            return MissingConflictEntity(entity: entity, id: id)
        })
    }

    private static func rebasedAction(
        _ action: SyncAction,
        missing: Bool,
        conflictsWithExisting: Bool
    ) -> SyncAction {
        switch (action, missing, conflictsWithExisting) {
        case (.update, true, _): .create
        case (.create, _, true): .update
        default: action
        }
    }

    private static func rebasedPayload(
        from payload: Data?,
        for action: SyncAction,
        entity: SyncEntity,
        entityId: UUID,
        in db: Database
    ) throws -> Data? {
        guard let payload,
              var object = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return payload }
        if action != .create {
            object.removeValue(forKey: "createdAt")
            return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        }
        let createdAt: Date? = switch entity {
        case .vault: try VaultRecord.fetchOne(db, key: entityId)?.createdAt
        case .project: try ProjectRecord.fetchOne(db, key: entityId)?.createdAt
        case .meeting: try MeetingRecord.fetchOne(db, key: entityId)?.createdAt
        default: nil
        }
        guard let createdAt else { return payload }
        object["createdAt"] = try JSONDecoder().decode(String.self, from: SyncJSON.encoder.encode(createdAt))
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

private struct MissingConflictEntity: Hashable {
    let entity: SyncEntity
    let id: UUID
}

enum SyncTransactionQueueError: Error {
    case invalidReceipt
    case pendingTransactions
    case serverCopyExists
    case readOnlyVault
}

private extension SyncScreenshotAttachment {
    init(mimeType: String, sha256: String, bytes: Data) {
        self.mimeType = mimeType
        self.sha256 = sha256
        self.bytes = bytes
    }
}

private extension SyncTranscriptPatchSegment {
    init(
        segmentId: UUID,
        startTime: Date,
        endTime: Date?,
        text: String,
        isConfirmed: Bool,
        audioSource: String?,
        speakerLabel: String?
    ) {
        self.segmentId = segmentId
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.isConfirmed = isConfirmed
        self.audioSource = audioSource
        self.speakerLabel = speakerLabel
    }
}

private struct RequeuedTransaction {
    let operations: [SyncOperationDraft]
    let segments: [UUID: [SyncTranscriptPatchSegment]]
    let deletions: [UUID: [UUID]]
    let attachments: [UUID: SyncScreenshotAttachment]
}
