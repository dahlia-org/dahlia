import Foundation
import GRDB

/// Repairs missing parents before historical migrations perform their foreign-key checks.
/// Only adds rows: recording IDs, meeting IDs, and all surviving content remain unchanged.
enum OrphanedRecordingRecovery {
    static func isNeeded(in db: Database) throws -> Bool {
        guard try db.tableExists("recording_sessions"), try db.tableExists("meetings"),
              try db.tableExists("vaults"), try !db.tableExists("workspaces") else { return false }
        // Early partial schemas can have a recording_sessions stub with only its ID.
        guard try db.columns(in: "recording_sessions").contains(where: { $0.name == "meetingId" }) else { return false }
        return try Bool.fetchOne(db, sql: """
        SELECT EXISTS (
            SELECT 1 FROM recording_sessions
            WHERE NOT EXISTS (SELECT 1 FROM meetings WHERE meetings.id = recording_sessions.meetingId)
        )
        """) == true
    }

    static func prepare(in db: Database, recoveryPath: String) throws {
        guard try isNeeded(in: db) else { return }
        let missing = try Row.fetchAll(db, sql: """
        SELECT meetingId, MIN(startedAt) AS startedAt, MAX(updatedAt) AS updatedAt
        FROM recording_sessions
        WHERE NOT EXISTS (SELECT 1 FROM meetings WHERE meetings.id = recording_sessions.meetingId)
        GROUP BY meetingId
        """)
        guard !missing.isEmpty else { return }

        // A session does not record its former workspace. Never guess an existing owner,
        // especially a Server-connected workspace that could publish recovered content.
        let workspaceID = UUID.v7()
        let now = Date.now
        let temporaryPath = URL(fileURLWithPath: recoveryPath).appending(path: workspaceID.uuidString).path
        try OrphanedRecordingRecoveryRecord.createTableIfNeeded(in: db)
        try db.execute(sql: """
        INSERT INTO vaults (id, path, name, createdAt, lastOpenedAt)
        VALUES (?, ?, ?, ?, ?)
        """, arguments: [workspaceID, temporaryPath, L10n.recoveredRecordings, now, Date(timeIntervalSince1970: 0)])
        try OrphanedRecordingRecoveryRecord(workspaceId: workspaceID).insert(db)
        for row in missing {
            // Preserve the stored key representation as well as its value.
            let meetingID: DatabaseValue = row["meetingId"]
            let startedAt: DatabaseValue = row["startedAt"]
            let updatedAt: DatabaseValue = row["updatedAt"]
            try db.execute(sql: """
            INSERT INTO meetings (id, vaultId, name, status, createdAt, updatedAt)
            VALUES (?, ?, ?, ?, ?, ?)
            """, arguments: [meetingID, workspaceID, L10n.recoveredRecording, MeetingStatus.transcriptNotFound.rawValue, startedAt, updatedAt])
        }
        // Unrelated corruption must roll back the entire repair, never be hidden.
        try db.checkForeignKeys()
    }

    static func needsFinalization(in db: Database) throws -> Bool {
        guard try db.tableExists(OrphanedRecordingRecoveryRecord.databaseTableName) else { return false }
        return try OrphanedRecordingRecoveryRecord.fetchCount(db) > 0
    }

    static func finish(in db: Database) throws {
        guard try needsFinalization(in: db) else { return }
        let pendingCount = try OrphanedRecordingRecoveryRecord.fetchCount(db)
        // Old vault schemas require a path; the current schema allows no output directory.
        // Only explicit recovery IDs authorize changing settings. Consume the checkpoint
        // in this same transaction so failure/restart cannot lose or replay finalization.
        try db.execute(sql: """
        UPDATE workspaces
        SET path = NULL, aiSettingsBackfilled = 1,
            generationSettings = json_set(generationSettings, '$.automaticProcessing', json('false'))
        WHERE id IN (SELECT workspaceId FROM orphaned_recording_recoveries)
            AND accountConnectionId IS NULL AND organizationId IS NULL
        """)
        guard db.changesCount == pendingCount else {
            throw DatabaseError(message: "Recovered workspace is missing or no longer local")
        }
        try OrphanedRecordingRecoveryRecord.deleteAll(db)
    }
}
