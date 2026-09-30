import GRDB

/// Preserves registered v47 data while removing the meeting/document identity constraint.
enum IndependentDocumentsMigration {
    static func migrate(in db: Database) throws {
        // Historical partial-schema fixtures have no meeting domain to migrate.
        guard try db.tableExists("meetings"), try db.tableExists("workspaces"),
              try db.columns(in: "meetings").contains(where: { $0.name == "workspace_id" }) else { return }
        try db.execute(sql: """
        CREATE UNIQUE INDEX meetings_workspace_identity ON meetings(workspace_id, id);
        CREATE TABLE documents_v48 (
            id BLOB PRIMARY KEY NOT NULL,
            workspace_id BLOB NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
            meetingId BLOB,
            kind TEXT NOT NULL CHECK (kind IN ('notes', 'summary', 'general')),
            title TEXT NOT NULL DEFAULT '',
            schemaVersion INTEGER NOT NULL DEFAULT 1,
            revision INTEGER NOT NULL DEFAULT 0,
            generation BLOB,
            checkpoint TEXT NOT NULL,
            checkpointSequence INTEGER NOT NULL DEFAULT 0,
            projectionSequence INTEGER NOT NULL DEFAULT 0,
            text TEXT NOT NULL DEFAULT '',
            createdAt DATETIME NOT NULL,
            updatedAt DATETIME NOT NULL,
            lastAccessedAt DATETIME,
            resident BOOLEAN NOT NULL DEFAULT 1,
            locallyEdited BOOLEAN NOT NULL DEFAULT 0,
            CHECK (kind != 'notes' OR meetingId IS NOT NULL),
            FOREIGN KEY (workspace_id, meetingId) REFERENCES meetings(workspace_id, id) ON DELETE CASCADE ON UPDATE CASCADE
        );
        INSERT INTO documents_v48
        SELECT d.id, m.workspace_id, d.meetingId, 'notes', '', d.schemaVersion, d.revision, d.generation,
          d.checkpoint, d.checkpointSequence, d.projectionSequence, d.text, d.createdAt, d.updatedAt,
          d.lastAccessedAt, d.resident, d.locallyEdited FROM documents d JOIN meetings m ON m.id = d.meetingId;
        -- v47 could retain recoveries after moving a document into a private copy.
        INSERT OR IGNORE INTO documents_v48 (id, workspace_id, meetingId, kind, checkpoint, createdAt, updatedAt)
        SELECT r.meetingId, m.workspace_id, r.meetingId, 'notes', 'AAA=', min(r.createdAt), max(r.createdAt)
        FROM document_recoveries r JOIN meetings m ON m.id = r.meetingId GROUP BY r.meetingId;
        CREATE TABLE document_updates_v48 (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            documentId BLOB NOT NULL REFERENCES documents(id) ON DELETE CASCADE ON UPDATE CASCADE,
            payload TEXT NOT NULL, pending BOOLEAN NOT NULL, createdAt DATETIME NOT NULL
        );
        INSERT INTO document_updates_v48 SELECT id, meetingId, payload, pending, createdAt FROM document_updates;
        CREATE TABLE document_recoveries_v48 (
            id BLOB PRIMARY KEY NOT NULL,
            documentId BLOB NOT NULL REFERENCES documents(id) ON DELETE CASCADE ON UPDATE CASCADE,
            blocksJSON TEXT NOT NULL, reason TEXT NOT NULL, pending BOOLEAN NOT NULL DEFAULT 0, createdAt DATETIME NOT NULL
        );
        INSERT INTO document_recoveries_v48 SELECT id, meetingId, blocksJSON, reason, pending, createdAt FROM document_recoveries;
        CREATE TABLE document_private_copies_v48 (
            id BLOB PRIMARY KEY NOT NULL,
            workspace_id BLOB NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
            meetingId BLOB,
            kind TEXT NOT NULL, title TEXT NOT NULL DEFAULT '',
            checkpoint TEXT NOT NULL, text TEXT NOT NULL, createdAt DATETIME NOT NULL, updatedAt DATETIME NOT NULL,
            FOREIGN KEY (workspace_id, meetingId) REFERENCES meetings(workspace_id, id) ON DELETE CASCADE ON UPDATE CASCADE
        );
        INSERT INTO document_private_copies_v48
        SELECT c.id, m.workspace_id, c.meetingId, 'notes', '', c.checkpoint, c.text, c.createdAt, c.updatedAt
        FROM document_private_copies c JOIN meetings m ON m.id = c.meetingId;
        DROP TABLE document_updates;
        DROP TABLE document_recoveries;
        DROP TABLE document_private_copies;
        DROP TABLE documents;
        ALTER TABLE documents_v48 RENAME TO documents;
        ALTER TABLE document_updates_v48 RENAME TO document_updates;
        ALTER TABLE document_recoveries_v48 RENAME TO document_recoveries;
        ALTER TABLE document_private_copies_v48 RENAME TO document_private_copies;
        CREATE UNIQUE INDEX document_meeting_notes_unique ON documents(meetingId) WHERE kind = 'notes';
        CREATE INDEX documents_workspace ON documents(workspace_id, id);
        CREATE INDEX document_updates_document ON document_updates(documentId, id);
        CREATE INDEX document_updates_pending ON document_updates(pending, documentId);
        CREATE TABLE document_local_archives_v48 (
            id BLOB PRIMARY KEY NOT NULL,
            workspace_id BLOB NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
            meetingId BLOB,
            name TEXT NOT NULL, payload TEXT NOT NULL, createdAt DATETIME NOT NULL
        );
        INSERT INTO document_local_archives_v48 SELECT * FROM document_local_archives;
        DROP TABLE document_local_archives;
        ALTER TABLE document_local_archives_v48 RENAME TO document_local_archives;
        """)
    }
}
