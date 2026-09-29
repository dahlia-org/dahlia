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
        try db.execute(sql: """
        INSERT INTO vaults (id, path, name, createdAt, lastOpenedAt)
        VALUES (?, ?, ?, ?, ?)
        """, arguments: [workspaceID, recoveryPath, L10n.recoveredRecordings, now, Date(timeIntervalSince1970: 0)])
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

    static func needsFinalization(in db: Database, recoveryPath: String) throws -> Bool {
        guard try db.tableExists("workspaces") else { return false }
        guard try db.columns(in: "workspaces").contains(where: { $0.name == "path" }) else { return false }
        return try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM workspaces WHERE path = ?)", arguments: [recoveryPath]) == true
    }

    static func finish(in db: Database, recoveryPath: String) throws {
        guard try db.tableExists("workspaces") else { return }
        // The private path is a durable marker across a failed migration/restart. Old
        // vault schemas require a path; the current schema allows no output directory.
        // Clear the marker and disable automatic processing atomically before startup.
        try db.execute(sql: """
        UPDATE workspaces
        SET path = NULL, aiSettingsBackfilled = 1,
            generationSettings = json_set(generationSettings, '$.automaticProcessing', json('false'))
        WHERE path = ? AND accountConnectionId IS NULL AND organizationId IS NULL
        """, arguments: [recoveryPath])
    }
}
