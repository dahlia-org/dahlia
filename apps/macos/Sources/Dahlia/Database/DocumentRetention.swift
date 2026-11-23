import DahliaMeetingAccess
import Foundation
import GRDB

enum DocumentRetention {
    /// Durable bytes are captured inside the deletion transaction; reconstruction runs off the DB lane.
    static func archive(documentID: UUID, rejectedUpdate: String? = nil, rejectedRecovery: String? = nil, in db: Database) throws {
        try db.execute(sql: """
        INSERT INTO document_local_archives (id, workspace_id, meetingId, name, payload, createdAt)
        SELECT ?, d.workspace_id, d.meetingId, coalesce(nullif(d.title, ''), m.name, ''), json_object(
            'checkpoint', d.checkpoint,
            'updates', json(CASE WHEN ? IS NULL
              THEN (SELECT json_group_array(payload) FROM document_updates WHERE documentId = d.id)
              ELSE json_insert((SELECT json_group_array(payload) FROM document_updates WHERE documentId = d.id), '$[#]', ?) END),
            'copies', json_array(),
            'recoveries', json(CASE WHEN ? IS NULL
              THEN (SELECT json_group_array(json(blocksJSON)) FROM document_recoveries WHERE documentId = d.id)
              ELSE json_insert((SELECT json_group_array(json(blocksJSON)) FROM document_recoveries WHERE documentId = d.id), '$[#]', json(?)) END),
            'legacy', NULL
        ), ? FROM documents d LEFT JOIN meetings m ON m.id = d.meetingId
        WHERE d.id = ? AND (? IS NOT NULL
          OR EXISTS(SELECT 1 FROM document_updates WHERE documentId = d.id AND pending = 1)
          OR EXISTS(SELECT 1 FROM document_recoveries WHERE documentId = d.id))
        """, arguments: [UUID.v7(), rejectedUpdate, rejectedUpdate, rejectedRecovery, rejectedRecovery, Date(), documentID, rejectedUpdate])
    }

    static func archiveBeforeRemoteDeletion(meetingID: UUID, rejectedUpdate: String? = nil, rejectedRecovery: String? = nil, in db: Database) throws {
        let documents = try DocumentRecord.filter(Column("meetingId") == meetingID).fetchAll(db)
        for document in documents {
            try archive(
                documentID: document.id,
                rejectedUpdate: document.kind == "notes" ? rejectedUpdate : nil,
                rejectedRecovery: document.kind == "notes" ? rejectedRecovery : nil,
                in: db
            )
        }
        let orphanUpdate = rejectedUpdate
        try db.execute(sql: """
        INSERT INTO document_local_archives (id, workspace_id, meetingId, name, payload, createdAt)
        SELECT ?, m.workspace_id, m.id, m.name, json_object(
            'checkpoint', NULL,
            'updates', json(CASE WHEN ? IS NULL THEN json_array() ELSE json_array(?) END),
            'copies', json((SELECT json_group_array(checkpoint) FROM document_private_copies WHERE meetingId = m.id)),
            'recoveries', json(CASE WHEN ? IS NULL THEN json_array() ELSE json_array(json(?)) END), 'legacy', (SELECT text FROM notes WHERE meetingId = m.id)
        ), ? FROM meetings m WHERE m.id = ? AND (? IS NOT NULL
          OR EXISTS(SELECT 1 FROM document_private_copies WHERE meetingId = m.id)
          OR EXISTS(SELECT 1 FROM notes WHERE meetingId = m.id AND text != ''))
        """, arguments: [UUID.v7(), orphanUpdate, orphanUpdate, rejectedRecovery, rejectedRecovery, Date(), meetingID, orphanUpdate])
    }

}
