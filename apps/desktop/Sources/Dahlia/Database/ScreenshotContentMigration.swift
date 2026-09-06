import GRDB

enum ScreenshotContentMigration {
    static func migrate(in db: Database) throws {
        guard try db.tableExists("screenshots") else { return }
        // Preserve the attachment guards, search triggers and existing indexes across the table rebuild.
        let objects = try String.fetchAll(db, sql: """
        SELECT sql FROM sqlite_master WHERE tbl_name = 'screenshots'
          AND type IN ('trigger', 'index') AND sql IS NOT NULL ORDER BY type, name
        """)
        let hasMeetingForeignKey = try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(screenshots)")
            .contains { $0["table"] as String == "meetings" }
        let meetingReference = hasMeetingForeignKey ? "REFERENCES meetings(id) ON DELETE CASCADE" : ""
        try db.execute(sql: """
        CREATE TABLE screenshots_v45 (
            id BLOB PRIMARY KEY,
            meetingId BLOB NOT NULL \(meetingReference),
            capturedAt DATETIME NOT NULL,
            imageData BLOB,
            mimeType TEXT NOT NULL,
            sessionId BLOB,
            ocrText TEXT,
            caption TEXT,
            contentHash TEXT,
            contentLength INTEGER,
            pixelWidth INTEGER,
            pixelHeight INTEGER,
            remoteReference TEXT
        );
        INSERT INTO screenshots_v45(id, meetingId, capturedAt, imageData, mimeType, sessionId, ocrText, caption, contentLength)
        SELECT id, meetingId, capturedAt, imageData, mimeType, sessionId, ocrText, caption, length(imageData) FROM screenshots;
        DROP TABLE screenshots;
        ALTER TABLE screenshots_v45 RENAME TO screenshots;
        """)
        for sql in objects {
            try db.execute(sql: sql)
        }
        // Establish canonical references for previously downloaded originals on the next metadata pull.
        if try db.tableExists("vaults"), try db.columns(in: "vaults").contains(where: { $0.name == "syncPullCursor" }) {
            try db.execute(sql: """
            UPDATE vaults SET syncPullCursor = NULL
            WHERE accountConnectionId IS NOT NULL AND syncConfirmedConnectionId = accountConnectionId
            """)
        }
    }
}
