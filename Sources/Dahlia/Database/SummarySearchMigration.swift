import Foundation
import GRDB

enum SummarySearchMigration {
    static func migrate(in db: Database) throws {
        let previousSecureDelete = try Int.fetchOne(db, sql: "PRAGMA secure_delete") ?? 0
        try db.execute(sql: "PRAGMA secure_delete = ON")
        defer { try? db.execute(sql: "PRAGMA secure_delete = \(previousSecureDelete)") }

        try db.execute(sql: """
        DROP TABLE search_documents_fts_vocab;
        DROP TABLE search_documents_fts;

        CREATE VIRTUAL TABLE search_documents_fts USING fts5(
            title,
            description,
            summary,
            calendar,
            tags,
            projectPath,
            content='',
            contentless_delete=1,
            detail=full,
            prefix='2 3',
            tokenize='dahlia_lindera_ipadic_v1'
        );
        CREATE VIRTUAL TABLE search_documents_fts_vocab USING fts5vocab(search_documents_fts, row);
        """)
        if try db.tableExists("summaries"), try db.tableExists("meetings") {
            try db.execute(sql: summaryTriggerSQL)
        }
        try db.execute(
            sql: "INSERT INTO search_documents_fts(search_documents_fts, rank) VALUES('secure-delete', 1)"
        )
        try db.execute(
            sql: """
            UPDATE search_index_state
            SET indexGeneration = indexGeneration + 1,
                indexRevision = indexRevision + 1,
                phase = 'pending', totalCount = 0, completedCount = 0,
                lastErrorCode = NULL, lastIntegrityCheckAt = NULL, updatedAt = ?
            WHERE indexKind = 'fts'
            """,
            arguments: [Date()]
        )
    }

    private static let summaryTriggerSQL = """
    CREATE TRIGGER search_queue_summaries_insert AFTER INSERT ON summaries BEGIN
        INSERT INTO search_index_jobs(indexKind, targetKind, targetKey, availableAt, updatedAt)
        VALUES('fts', 'meeting', new.meetingId, unixepoch('subsec'), unixepoch('subsec'))
        ON CONFLICT(indexKind, targetKind, targetKey) DO UPDATE SET
            generation = generation + 1, status = 'pending', availableAt = excluded.availableAt,
            claimedAt = NULL, leaseExpiresAt = NULL, lastErrorCode = NULL, updatedAt = excluded.updatedAt;
    END;
    CREATE TRIGGER search_queue_summaries_update AFTER UPDATE OF document ON summaries BEGIN
        INSERT INTO search_index_jobs(indexKind, targetKind, targetKey, availableAt, updatedAt)
        VALUES('fts', 'meeting', new.meetingId, unixepoch('subsec'), unixepoch('subsec'))
        ON CONFLICT(indexKind, targetKind, targetKey) DO UPDATE SET
            generation = generation + 1, status = 'pending', availableAt = excluded.availableAt,
            claimedAt = NULL, leaseExpiresAt = NULL, lastErrorCode = NULL, updatedAt = excluded.updatedAt;
    END;
    CREATE TRIGGER search_queue_summaries_delete AFTER DELETE ON summaries BEGIN
        INSERT INTO search_index_jobs(indexKind, targetKind, targetKey, availableAt, updatedAt)
        SELECT 'fts', 'meeting', old.meetingId, unixepoch('subsec'), unixepoch('subsec')
        WHERE EXISTS(SELECT 1 FROM meetings WHERE id = old.meetingId)
        ON CONFLICT(indexKind, targetKind, targetKey) DO UPDATE SET
            generation = generation + 1, status = 'pending', availableAt = excluded.availableAt,
            claimedAt = NULL, leaseExpiresAt = NULL, lastErrorCode = NULL, updatedAt = excluded.updatedAt;
    END;
    """
}
