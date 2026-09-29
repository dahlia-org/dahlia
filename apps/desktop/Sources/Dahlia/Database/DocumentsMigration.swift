import GRDB

enum DocumentsMigration {
    static func migrate(in db: Database) throws {
        try db.execute(sql: """
        CREATE TABLE documents (
            id BLOB PRIMARY KEY NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
            meetingId BLOB NOT NULL UNIQUE REFERENCES meetings(id) ON DELETE CASCADE,
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
            CHECK (id = meetingId)
        );
        CREATE TABLE document_updates (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            meetingId BLOB NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
            payload TEXT NOT NULL,
            pending BOOLEAN NOT NULL,
            createdAt DATETIME NOT NULL
        );
        CREATE INDEX document_updates_meeting ON document_updates(meetingId, id);
        CREATE INDEX document_updates_pending ON document_updates(pending, meetingId);
        CREATE TABLE document_recoveries (
            id BLOB PRIMARY KEY NOT NULL,
            meetingId BLOB NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
            blocksJSON TEXT NOT NULL,
            reason TEXT NOT NULL,
            pending BOOLEAN NOT NULL DEFAULT 0,
            createdAt DATETIME NOT NULL
        );
        CREATE TABLE document_private_copies (
            id BLOB PRIMARY KEY NOT NULL,
            meetingId BLOB NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
            checkpoint TEXT NOT NULL,
            text TEXT NOT NULL,
            createdAt DATETIME NOT NULL,
            updatedAt DATETIME NOT NULL
        );
        CREATE TABLE document_local_archives (
            id BLOB PRIMARY KEY NOT NULL,
            workspace_id BLOB NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
            meetingId BLOB NOT NULL,
            name TEXT NOT NULL,
            payload TEXT NOT NULL,
            createdAt DATETIME NOT NULL
        );
        CREATE TABLE document_legacy_imports (
            meetingId BLOB PRIMARY KEY NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
            importedAt DATETIME NOT NULL
        );
        """)
    }
}
