import Foundation
import GRDB

enum MeetingSyncDeletionMode: String, DatabaseValueConvertible, Sendable {
    case deleteOnly
    case replaceAfterRestore
}

struct MeetingSyncJob: Sendable {
    let id: Int64
    let vaultId: UUID
    let meetingId: UUID
    let targetKind: String
    let generation: Int
    let attempts: Int
}

struct VaultSyncJob: Sendable {
    let vaultId: UUID
    let generation: Int
    let attempts: Int
}

enum MeetingSyncQueue {
    static let transcriptSettleDelay: TimeInterval = 30
    static let leaseDuration: TimeInterval = 120
    static let meetingDeleteConfirmationThreshold = 100

    static func enqueue(meetingId: UUID, availableAt: Date = .now, in db: Database) throws {
        try db.execute(
            sql: """
            INSERT INTO meeting_sync_jobs(vaultId, meetingId, targetKind, availableAt)
            SELECT vaultId, id, 'upload', ? FROM meetings WHERE id = ?
            ON CONFLICT(targetKind, meetingId) DO UPDATE SET
                generation = generation + 1, vaultId = excluded.vaultId, status = 'pending', attempts = 0,
                availableAt = excluded.availableAt, claimedAt = NULL, leaseExpiresAt = NULL,
                lastErrorCode = NULL, updatedAt = unixepoch('subsec')
            """,
            arguments: [availableAt, meetingId]
        )
    }

    static func reconcile(dbQueue: DatabaseQueue) async throws {
        try await dbQueue.write { db in
            guard try !batchPersistenceIsActive(in: db) else { return }
            try db.execute(sql: """
            INSERT INTO vault_sync_jobs(vaultId)
            SELECT id FROM vaults WHERE syncEnabled = 1 AND syncDeletionMode IS NULL
            ON CONFLICT(vaultId) DO NOTHING;
            """)
            try db.execute(
                sql: """
                WITH enabled_meetings AS (
                    SELECT meetings.* FROM meetings
                    JOIN vaults ON vaults.id = meetings.vaultId AND vaults.syncEnabled = 1
                ), transcript_signatures AS (
                    SELECT transcript_segments.meetingId, count(*) AS segmentCount,
                        max(transcript_segments.id) AS maxSegmentId,
                        sum(CASE WHEN isConfirmed = 1 THEN 1 ELSE 0 END) AS confirmedCount
                    FROM transcript_segments
                    JOIN enabled_meetings ON enabled_meetings.id = transcript_segments.meetingId
                    GROUP BY transcript_segments.meetingId
                ), recording_signatures AS (
                    SELECT recording_sessions.meetingId, max(endedAt) AS recordingEndedAt,
                        max(batchCompletedAt) AS batchCompletedAt
                    FROM recording_sessions
                    JOIN enabled_meetings ON enabled_meetings.id = recording_sessions.meetingId
                    GROUP BY recording_sessions.meetingId
                ), signatures AS (
                    SELECT enabled_meetings.vaultId, enabled_meetings.id AS meetingId,
                        coalesce(transcript_signatures.segmentCount, 0) AS segmentCount,
                        transcript_signatures.maxSegmentId,
                        coalesce(transcript_signatures.confirmedCount, 0) AS confirmedCount,
                        recording_signatures.recordingEndedAt, recording_signatures.batchCompletedAt
                    FROM enabled_meetings
                    LEFT JOIN transcript_signatures ON transcript_signatures.meetingId = enabled_meetings.id
                    LEFT JOIN recording_signatures ON recording_signatures.meetingId = enabled_meetings.id
                )
                INSERT INTO meeting_sync_jobs(
                    vaultId, meetingId, targetKind, segmentCount, maxSegmentId, confirmedCount,
                    recordingEndedAt, batchCompletedAt
                )
                SELECT signatures.vaultId, signatures.meetingId, 'upload', signatures.segmentCount,
                    signatures.maxSegmentId, signatures.confirmedCount, signatures.recordingEndedAt,
                    signatures.batchCompletedAt
                FROM signatures
                LEFT JOIN meeting_sync_success ON meeting_sync_success.meetingId = signatures.meetingId
                WHERE meeting_sync_success.meetingId IS NULL
                   OR meeting_sync_success.segmentCount IS NOT signatures.segmentCount
                   OR meeting_sync_success.maxSegmentId IS NOT signatures.maxSegmentId
                   OR meeting_sync_success.confirmedCount IS NOT signatures.confirmedCount
                   OR meeting_sync_success.recordingEndedAt IS NOT signatures.recordingEndedAt
                   OR meeting_sync_success.batchCompletedAt IS NOT signatures.batchCompletedAt
                ON CONFLICT(targetKind, meetingId) DO UPDATE SET
                    generation = generation + 1, status = 'pending', attempts = 0,
                    segmentCount = excluded.segmentCount, maxSegmentId = excluded.maxSegmentId,
                    confirmedCount = excluded.confirmedCount, recordingEndedAt = excluded.recordingEndedAt,
                    batchCompletedAt = excluded.batchCompletedAt, availableAt = unixepoch('subsec'),
                    claimedAt = NULL, leaseExpiresAt = NULL, lastErrorCode = NULL,
                    updatedAt = unixepoch('subsec')
                WHERE meeting_sync_jobs.segmentCount IS NOT excluded.segmentCount
                   OR meeting_sync_jobs.maxSegmentId IS NOT excluded.maxSegmentId
                   OR meeting_sync_jobs.confirmedCount IS NOT excluded.confirmedCount
                   OR meeting_sync_jobs.recordingEndedAt IS NOT excluded.recordingEndedAt
                   OR meeting_sync_jobs.batchCompletedAt IS NOT excluded.batchCompletedAt
                """
            )
        }
    }

    static func batchPersistenceIsActive(dbQueue: DatabaseQueue) async throws -> Bool {
        try await dbQueue.read { db in try batchPersistenceIsActive(in: db) }
    }

    private static func batchPersistenceIsActive(in db: Database) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: """
            SELECT EXISTS (
                SELECT 1 FROM recording_sessions
                WHERE transcriptionMode = 'batch' AND batchLastAttemptAt IS NOT NULL
                  AND batchDiscardedAt IS NULL AND batchLastError IS NULL
                  AND (batchCompletedAt IS NULL OR batchLastAttemptAt > batchCompletedAt)
            )
            """
        ) ?? false
    }

    static func prepareRestore(dbQueue: DatabaseQueue) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE vaults SET syncDeletionMode = ?, syncDeletionApproved = 1,
                    syncDeletionConnectionId = accountConnectionId
                WHERE syncEnabled = 1;
                UPDATE screenshots SET syncUploadedConnectionId = NULL
                WHERE meetingId IN (
                    SELECT meetings.id FROM meetings
                    JOIN vaults ON vaults.id = meetings.vaultId
                    WHERE vaults.syncDeletionMode = ?
                );
                DELETE FROM meeting_sync_jobs
                WHERE vaultId IN (SELECT id FROM vaults WHERE syncDeletionMode = ?);
                DELETE FROM vault_sync_jobs
                WHERE vaultId IN (SELECT id FROM vaults WHERE syncDeletionMode = ?);
                """,
                arguments: [
                    MeetingSyncDeletionMode.replaceAfterRestore.rawValue,
                    MeetingSyncDeletionMode.replaceAfterRestore.rawValue,
                    MeetingSyncDeletionMode.replaceAfterRestore.rawValue,
                    MeetingSyncDeletionMode.replaceAfterRestore.rawValue,
                ]
            )
        }
    }

    static func claimVault(dbQueue: DatabaseQueue) async throws -> VaultSyncJob? {
        try await dbQueue.write { db in
            let now = Date()
            guard let row = try Row.fetchOne(db, sql: """
            SELECT vault_sync_jobs.vaultId, generation, attempts
            FROM vault_sync_jobs
            JOIN vaults ON vaults.id = vault_sync_jobs.vaultId
            WHERE vaults.syncEnabled = 1 AND vaults.syncDeletionMode IS NULL
              AND vaults.accountConnectionId IS NOT NULL
              AND vaults.syncConfirmedConnectionId = vaults.accountConnectionId
              AND availableAt <= ?
              AND (status IN ('pending', 'failed') OR leaseExpiresAt < ?)
            ORDER BY availableAt, vault_sync_jobs.vaultId LIMIT 1
            """, arguments: [now, now]) else { return nil }
            let job = VaultSyncJob(
                vaultId: row["vaultId"],
                generation: row["generation"],
                attempts: (row["attempts"] as Int) + 1
            )
            try db.execute(sql: """
            UPDATE vault_sync_jobs SET status = 'running', attempts = attempts + 1,
                claimedAt = ?, leaseExpiresAt = ?, updatedAt = ?
            WHERE vaultId = ? AND generation = ?
            """, arguments: [now, now.addingTimeInterval(leaseDuration), now, job.vaultId, job.generation])
            return job
        }
    }

    static func complete(_ job: VaultSyncJob, dbQueue: DatabaseQueue) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM vault_sync_jobs WHERE vaultId = ? AND generation = ?",
                arguments: [job.vaultId, job.generation]
            )
        }
    }

    static func fail(_ job: VaultSyncJob, code: String, permanently: Bool, dbQueue: DatabaseQueue) async throws {
        let availableAt = permanently
            ? Date.distantFuture
            : Date().addingTimeInterval(min(pow(2, Double(min(job.attempts, 8))), 300))
        try await dbQueue.write { db in
            try db.execute(sql: """
            UPDATE vault_sync_jobs SET status = 'failed', availableAt = ?, claimedAt = NULL,
                leaseExpiresAt = NULL, lastErrorCode = ?, updatedAt = ?
            WHERE vaultId = ? AND generation = ?
            """, arguments: [availableAt, code, Date(), job.vaultId, job.generation])
        }
    }

    static func claim(dbQueue: DatabaseQueue) async throws -> MeetingSyncJob? {
        try await dbQueue.write { db in
            guard try !batchPersistenceIsActive(in: db) else { return nil }
            let now = Date()
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT meeting_sync_jobs.id, meeting_sync_jobs.vaultId, meeting_sync_jobs.meetingId,
                       targetKind, generation, attempts
                FROM meeting_sync_jobs
                JOIN vaults ON vaults.id = meeting_sync_jobs.vaultId
                WHERE vaults.syncEnabled = 1 AND vaults.syncDeletionMode IS NULL
                  AND vaults.accountConnectionId IS NOT NULL
                  AND vaults.syncConfirmedConnectionId = vaults.accountConnectionId
                  AND NOT EXISTS (
                      SELECT 1 FROM vault_sync_jobs
                      WHERE vault_sync_jobs.vaultId = meeting_sync_jobs.vaultId
                  )
                  AND meeting_sync_jobs.availableAt <= ?
                  AND (meeting_sync_jobs.status IN ('pending', 'failed') OR meeting_sync_jobs.leaseExpiresAt < ?)
                  AND (
                      meeting_sync_jobs.targetKind != 'meetingDelete'
                      OR vaults.syncBulkDeleteApproved = 1
                      OR (SELECT count(*) FROM meeting_sync_jobs pending_deletes
                          WHERE pending_deletes.vaultId = meeting_sync_jobs.vaultId
                            AND pending_deletes.targetKind = 'meetingDelete') < ?
                  )
                ORDER BY meeting_sync_jobs.availableAt, meeting_sync_jobs.id LIMIT 1
                """,
                arguments: [now, now, meetingDeleteConfirmationThreshold]
            ) else { return nil }
            let job = MeetingSyncJob(
                id: row["id"],
                vaultId: row["vaultId"],
                meetingId: row["meetingId"],
                targetKind: row["targetKind"],
                generation: row["generation"],
                attempts: (row["attempts"] as Int) + 1
            )
            try db.execute(
                sql: """
                UPDATE meeting_sync_jobs SET status = 'running', attempts = attempts + 1,
                    claimedAt = ?, leaseExpiresAt = ?, updatedAt = ?
                WHERE id = ? AND generation = ?
                """,
                arguments: [now, now.addingTimeInterval(leaseDuration), now, job.id, job.generation]
            )
            return job
        }
    }

    static func complete(_ job: MeetingSyncJob, dbQueue: DatabaseQueue) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM meeting_sync_jobs WHERE id = ? AND generation = ?",
                arguments: [job.id, job.generation]
            )
            if job.targetKind == "upload", db.changesCount > 0 {
                try db.execute(
                    sql: """
                    INSERT INTO meeting_sync_success(
                        meetingId, segmentCount, maxSegmentId, confirmedCount, recordingEndedAt, batchCompletedAt
                    )
                    SELECT meetings.id,
                        (SELECT count(*) FROM transcript_segments WHERE meetingId = meetings.id),
                        (SELECT max(id) FROM transcript_segments WHERE meetingId = meetings.id),
                        (SELECT count(*) FROM transcript_segments
                            WHERE meetingId = meetings.id AND isConfirmed = 1),
                        (SELECT max(endedAt) FROM recording_sessions WHERE meetingId = meetings.id),
                        (SELECT max(batchCompletedAt) FROM recording_sessions WHERE meetingId = meetings.id)
                    FROM meetings WHERE meetings.id = ?
                    ON CONFLICT(meetingId) DO UPDATE SET
                        segmentCount = excluded.segmentCount, maxSegmentId = excluded.maxSegmentId,
                        confirmedCount = excluded.confirmedCount, recordingEndedAt = excluded.recordingEndedAt,
                        batchCompletedAt = excluded.batchCompletedAt
                    """,
                    arguments: [job.meetingId]
                )
            }
            if job.targetKind == "meetingDelete" {
                try db.execute(
                    sql: """
                    UPDATE vaults SET syncBulkDeleteApproved = 0
                    WHERE id = ? AND NOT EXISTS (
                        SELECT 1 FROM meeting_sync_jobs
                        WHERE vaultId = ? AND targetKind = 'meetingDelete'
                    )
                    """,
                    arguments: [job.vaultId, job.vaultId]
                )
            }
        }
    }

    static func fail(_ job: MeetingSyncJob, code: String, dbQueue: DatabaseQueue) async throws {
        let delay = min(pow(2, Double(min(job.attempts, 8))), 300)
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE meeting_sync_jobs SET status = 'failed', availableAt = ?, claimedAt = NULL,
                    leaseExpiresAt = NULL, lastErrorCode = ?, updatedAt = ?
                WHERE id = ? AND generation = ?
                """,
                arguments: [Date().addingTimeInterval(delay), code, Date(), job.id, job.generation]
            )
        }
    }

    static func block(_ job: MeetingSyncJob, code: String, dbQueue: DatabaseQueue) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE meeting_sync_jobs SET status = 'failed', availableAt = ?, claimedAt = NULL,
                    leaseExpiresAt = NULL, lastErrorCode = ?, updatedAt = ?
                WHERE id = ? AND generation = ?
                """,
                arguments: [Date.distantFuture, code, Date(), job.id, job.generation]
            )
        }
    }
}
