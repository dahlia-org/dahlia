import Foundation
import GRDB

enum DocumentRetention {
    /// Remote deletion must not destroy private notes, pending edits, or preserved conflict copies.
    /// Capture durable bytes in SQL; JSC reconstruction happens outside this transaction when opened.
    static func archiveBeforeRemoteDeletion(meetingID: UUID, rejectedUpdate: String? = nil, in db: Database) throws {
        try db.execute(sql: """
        INSERT INTO document_local_archives (id, workspace_id, meetingId, name, payload, createdAt)
        SELECT ?, m.workspace_id, m.id, m.name, json_object(
            'checkpoint', (SELECT checkpoint FROM documents WHERE id = m.id),
            'updates', json(CASE WHEN ? IS NULL
                THEN (SELECT json_group_array(payload) FROM document_updates WHERE meetingId = m.id)
                ELSE json_insert((SELECT json_group_array(payload) FROM document_updates WHERE meetingId = m.id), '$[#]', ?) END),
            'copies', json((SELECT json_group_array(checkpoint) FROM document_private_copies WHERE meetingId = m.id)),
            'recoveries', json((SELECT json_group_array(json(blocksJSON)) FROM document_recoveries WHERE meetingId = m.id)),
            'legacy', (SELECT text FROM notes WHERE meetingId = m.id)
        ), ? FROM meetings m WHERE m.id = ? AND (
            ? IS NOT NULL OR EXISTS(SELECT 1 FROM document_updates WHERE meetingId = m.id AND pending = 1)
            OR EXISTS(SELECT 1 FROM document_private_copies WHERE meetingId = m.id)
            OR EXISTS(SELECT 1 FROM document_recoveries WHERE meetingId = m.id)
            OR EXISTS(SELECT 1 FROM notes WHERE meetingId = m.id AND text != '')
        )
        """, arguments: [UUID.v7(), rejectedUpdate, rejectedUpdate, Date(), meetingID, rejectedUpdate])
    }

    static func usedBytes(in db: Database) throws -> Int {
        try Int.fetchOne(db, sql: """
        SELECT coalesce(sum(length(CAST(d.checkpoint AS BLOB)) + length(CAST(d.text AS BLOB)) +
          coalesce((SELECT sum(length(CAST(payload AS BLOB))) FROM document_updates WHERE meetingId = d.id), 0)), 0)
        FROM documents d JOIN meetings m ON m.id = d.meetingId JOIN workspaces w ON w.id = m.workspace_id
        WHERE w.accountConnectionId IS NOT NULL AND d.resident = 1
        """) ?? 0
    }

    static func evict(meetingID: UUID, protectedWorkspaces: Set<UUID>, in db: Database) throws -> Int {
        guard let meeting = try MeetingRecord.fetchOne(db, key: meetingID), !protectedWorkspaces.contains(meeting.workspaceId),
              let workspace = try WorkspaceRecord.fetchOne(db, key: meeting.workspaceId), workspace.accountConnectionId != nil,
              workspace.syncRecoveryState == nil,
              let document = try DocumentRecord.fetchOne(db, key: meetingID), document.generation != nil, document.resident,
              try !RecordingSessionRecord.hasActiveRecording(workspaceId: workspace.id, in: db),
              try Bool.fetchOne(db, sql: """
              SELECT EXISTS(SELECT 1 FROM document_updates WHERE meetingId = ? AND pending = 1)
                OR EXISTS(SELECT 1 FROM document_private_copies WHERE meetingId = ?)
                OR EXISTS(SELECT 1 FROM document_recoveries WHERE meetingId = ?)
              """, arguments: [meetingID, meetingID, meetingID]) != true else { return 0 }
        let bytes = try document.checkpoint.utf8.count + document.text.utf8.count + (Int.fetchOne(
            db,
            sql: "SELECT sum(length(CAST(payload AS BLOB))) FROM document_updates WHERE meetingId = ?",
            arguments: [meetingID]
        ) ?? 0)
        try db.execute(sql: "DELETE FROM document_updates WHERE meetingId = ?", arguments: [meetingID])
        try db.execute(
            sql: "UPDATE documents SET checkpoint = 'AAA=', text = '', checkpointSequence = 0, projectionSequence = 0, resident = 0 WHERE id = ?",
            arguments: [meetingID]
        )
        return bytes
    }

    static func hasPrivateData(workspaceID: UUID, in db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: """
        SELECT EXISTS(SELECT 1 FROM document_local_archives WHERE workspace_id = ?)
          OR EXISTS(SELECT 1 FROM meetings m WHERE m.workspace_id = ? AND (
            EXISTS(SELECT 1 FROM document_updates WHERE meetingId = m.id AND pending = 1)
            OR EXISTS(SELECT 1 FROM document_private_copies WHERE meetingId = m.id)
            OR EXISTS(SELECT 1 FROM document_recoveries WHERE meetingId = m.id)
            OR EXISTS(SELECT 1 FROM notes WHERE meetingId = m.id AND text != '')
          ))
        """, arguments: [workspaceID, workspaceID]) ?? false
    }
}
