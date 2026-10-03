import GRDB

/// Creates the final document schema directly for released databases and fresh installations.
enum DocumentsMigration {
    static let documentSQL = """
    CREATE TABLE "documents" (
        id BLOB PRIMARY KEY NOT NULL,
        workspace_id BLOB NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
        meetingId BLOB,
        kind TEXT NOT NULL CHECK (kind IN ('notes', 'summary', 'general')),
        title TEXT NOT NULL DEFAULT '',
        schemaVersion INTEGER NOT NULL DEFAULT 2,
        revision INTEGER NOT NULL DEFAULT 0,
        generation BLOB,
        checkpoint TEXT NOT NULL,
        checkpointSequence INTEGER NOT NULL DEFAULT 0,
        projectionSequence INTEGER NOT NULL DEFAULT 0,
        recoverySequence INTEGER NOT NULL DEFAULT 0,
        recoveryCursor TEXT,
        text TEXT NOT NULL DEFAULT '',
        createdAt DATETIME NOT NULL,
        updatedAt DATETIME NOT NULL,
        lastAccessedAt DATETIME,
        resident BOOLEAN NOT NULL DEFAULT 1,
        locallyEdited BOOLEAN NOT NULL DEFAULT 0,
        CHECK (kind != 'notes' OR meetingId IS NOT NULL),
        FOREIGN KEY (workspace_id, meetingId) REFERENCES meetings(workspace_id, id) ON DELETE CASCADE ON UPDATE CASCADE
    )
    """

    static let recoverySQL = """
    CREATE TABLE "document_recoveries" (
        id BLOB PRIMARY KEY NOT NULL,
        documentId BLOB NOT NULL REFERENCES documents(id) ON DELETE CASCADE ON UPDATE CASCADE,
        serverSequence INTEGER, blocksJSON TEXT NOT NULL, reason TEXT NOT NULL, pending BOOLEAN NOT NULL DEFAULT 0, createdAt DATETIME NOT NULL
    )
    """

    static func upgradeDevelopmentDefault(in db: Database) throws {
        let columns = try db.columns(in: "documents")
        let expected = [
            "id",
            "workspace_id",
            "meetingId",
            "kind",
            "title",
            "schemaVersion",
            "revision",
            "generation",
            "checkpoint",
            "checkpointSequence",
            "projectionSequence",
            "recoverySequence",
            "recoveryCursor",
            "text",
            "createdAt",
            "updatedAt",
            "lastAccessedAt",
            "resident",
            "locallyEdited",
        ]
        if columns.map(\.name) != expected || columns.first(where: { $0.name == "schemaVersion" })?.defaultValueSQL != "2" {
            guard Set(columns.map(\.name)) == Set(expected) else { throw DatabaseError(
                resultCode: .SQLITE_ERROR,
                message: "Unsupported development Documents schema"
            ) }
            try db.execute(sql: documentSQL.replacingOccurrences(of: "CREATE TABLE \"documents\"", with: "CREATE TABLE documents_v54"))
            let names = expected.map { "\"\($0)\"" }.joined(separator: ", ")
            try db.execute(sql: """
            INSERT INTO documents_v54 (\(names)) SELECT \(names) FROM documents;
            DROP TABLE documents;
            ALTER TABLE documents_v54 RENAME TO documents;
            CREATE UNIQUE INDEX document_meeting_notes_unique ON documents(meetingId) WHERE kind = 'notes';
            CREATE INDEX documents_workspace ON documents(workspace_id, id);
            """)
        }
        if try db.columns(in: "document_recoveries").map(\.name) != [
            "id",
            "documentId",
            "serverSequence",
            "blocksJSON",
            "reason",
            "pending",
            "createdAt",
        ] {
            try db.execute(sql: recoverySQL.replacingOccurrences(
                of: "CREATE TABLE \"document_recoveries\"",
                with: "CREATE TABLE document_recoveries_v54"
            ))
            try db.execute(sql: """
            INSERT INTO document_recoveries_v54 (id, documentId, serverSequence, blocksJSON, reason, pending, createdAt)
            SELECT id, documentId, serverSequence, blocksJSON, reason, pending, createdAt FROM document_recoveries;
            DROP TABLE document_recoveries;
            ALTER TABLE document_recoveries_v54 RENAME TO document_recoveries;
            """)
        }
    }

    static func migrate(in db: Database) throws {
        guard try db.tableExists("meetings"), try db.tableExists("workspaces"),
              try db.columns(in: "meetings").contains(where: { $0.name == "workspace_id" }) else { return }
        try db.execute(sql: """
        CREATE TABLE document_legacy_imports (
            meetingId BLOB PRIMARY KEY NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
            importedAt DATETIME NOT NULL
        );
        CREATE TABLE "document_local_archives" (
            id BLOB PRIMARY KEY NOT NULL,
            workspace_id BLOB NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
            meetingId BLOB,
            name TEXT NOT NULL, payload TEXT NOT NULL, createdAt DATETIME NOT NULL
        );
        CREATE TABLE "document_private_copies" (
            id BLOB PRIMARY KEY NOT NULL,
            workspace_id BLOB NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
            meetingId BLOB,
            kind TEXT NOT NULL, title TEXT NOT NULL DEFAULT '',
            checkpoint TEXT NOT NULL, text TEXT NOT NULL, createdAt DATETIME NOT NULL, updatedAt DATETIME NOT NULL,
            FOREIGN KEY (workspace_id, meetingId) REFERENCES meetings(workspace_id, id) ON DELETE CASCADE ON UPDATE CASCADE
        );
        \(recoverySQL);
        CREATE TABLE "document_updates" (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            documentId BLOB NOT NULL REFERENCES documents(id) ON DELETE CASCADE ON UPDATE CASCADE,
            payload TEXT NOT NULL, pending BOOLEAN NOT NULL, createdAt DATETIME NOT NULL
        );
        \(documentSQL);
        CREATE UNIQUE INDEX document_meeting_notes_unique ON documents(meetingId) WHERE kind = 'notes';
        CREATE INDEX document_recoveries_document ON document_recoveries(documentId, createdAt);
        CREATE INDEX document_updates_document ON document_updates(documentId, id);
        CREATE INDEX document_updates_pending ON document_updates(pending, documentId);
        CREATE INDEX documents_workspace ON documents(workspace_id, id);
        CREATE UNIQUE INDEX meetings_workspace_identity ON meetings(workspace_id, id);
        """)
    }
}
