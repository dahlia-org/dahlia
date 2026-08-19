import DahliaMeetingAccess
import Foundation
import GRDB

enum SearchDocumentsMigration {
    static let analyzerVersion = SearchFTS5Tokenizer.name
    static let analyzerConfigurationHash = SearchFTS5Tokenizer.configurationHash

    static func migrate(in db: Database) throws {
        try requireContentlessDeleteSupport(in: db)
        try db.execute(sql: schemaSQL)
        let sourceTables = [
            "vaults", "meetings", "projects", "meeting_tags", "tags", "calendar_events",
        ]
        if try sourceTables.allSatisfy({ try db.tableExists($0) }) {
            try db.execute(sql: triggerSQL)
        }
        try db.execute(
            sql: "INSERT INTO search_documents_fts(search_documents_fts, rank) VALUES('secure-delete', 1)"
        )
        try db.execute(
            sql: """
            INSERT INTO search_index_state(
                indexKind, analyzerVersion, analyzerConfigurationHash, indexGeneration,
                indexRevision, phase, updatedAt
            ) VALUES('fts', ?, ?, 1, 0, 'pending', ?)
            """,
            arguments: [analyzerVersion, analyzerConfigurationHash, Date()]
        )
    }

    private static func requireContentlessDeleteSupport(in db: Database) throws {
        let version = try String.fetchOne(db, sql: "SELECT sqlite_version()") ?? "0"
        let components = version.split(separator: ".").prefix(3).compactMap { Int($0) }
        let normalized = components + Array(repeating: 0, count: max(0, 3 - components.count))
        guard Array(normalized.prefix(3)).lexicographicallyPrecedes([3, 43, 0]) == false else {
            throw DatabaseError(
                resultCode: .SQLITE_ERROR,
                message: "Search index requires SQLite 3.43.0 or later; found \(version)"
            )
        }
    }

    private static let schemaSQL = """
    CREATE TABLE search_documents (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        kind TEXT NOT NULL CHECK(kind IN ('meeting', 'project')),
        sourceId BLOB NOT NULL,
        vaultId BLOB NOT NULL,
        meetingId BLOB,
        projectId BLOB,
        sourceContentHash TEXT NOT NULL,
        indexGeneration INTEGER NOT NULL,
        updatedAt DATETIME NOT NULL,
        UNIQUE(kind, sourceId)
    );

    CREATE INDEX search_documents_meeting
        ON search_documents(meetingId, kind, indexGeneration);
    CREATE INDEX search_documents_project
        ON search_documents(projectId, kind, indexGeneration);

    -- Contentless FTS stores tokens only; selecting these columns directly returns NULL by design.
    CREATE VIRTUAL TABLE search_documents_fts USING fts5(
        title,
        description,
        calendar,
        tags,
        projectPath,
        content='',
        contentless_delete=1,
        detail=column,
        prefix='2 3',
        tokenize='dahlia_lindera_ipadic_v1'
    );
    CREATE VIRTUAL TABLE search_documents_fts_vocab USING fts5vocab(search_documents_fts, row);

    CREATE TABLE search_index_jobs (
        indexKind TEXT NOT NULL CHECK(indexKind IN ('fts', 'vector')),
        targetKind TEXT NOT NULL,
        targetKey BLOB NOT NULL,
        generation INTEGER NOT NULL DEFAULT 1,
        priority INTEGER NOT NULL DEFAULT 0,
        status TEXT NOT NULL DEFAULT 'pending'
            CHECK(status IN ('pending', 'processing')),
        attempts INTEGER NOT NULL DEFAULT 0,
        availableAt DATETIME NOT NULL,
        claimedAt DATETIME,
        leaseExpiresAt DATETIME,
        lastErrorCode TEXT,
        updatedAt DATETIME NOT NULL,
        PRIMARY KEY(indexKind, targetKind, targetKey)
    ) WITHOUT ROWID;
    CREATE INDEX search_index_jobs_schedule
        ON search_index_jobs(indexKind, status, availableAt, priority DESC);

    CREATE TABLE search_index_state (
        indexKind TEXT PRIMARY KEY CHECK(indexKind IN ('fts', 'vector')),
        analyzerVersion TEXT NOT NULL,
        analyzerConfigurationHash TEXT NOT NULL,
        indexGeneration INTEGER NOT NULL,
        indexRevision INTEGER NOT NULL,
        phase TEXT NOT NULL CHECK(phase IN ('pending', 'metadata', 'ready', 'failed')),
        totalCount INTEGER NOT NULL DEFAULT 0,
        completedCount INTEGER NOT NULL DEFAULT 0,
        lastErrorCode TEXT,
        lastIntegrityCheckAt DATETIME,
        updatedAt DATETIME NOT NULL
    ) WITHOUT ROWID;

    CREATE TRIGGER search_revision_jobs_insert AFTER INSERT ON search_index_jobs
    WHEN new.indexKind = 'fts' BEGIN
        UPDATE search_index_state
        SET indexRevision = indexRevision + 1, updatedAt = unixepoch('subsec')
        WHERE indexKind = 'fts';
    END;
    CREATE TRIGGER search_revision_jobs_generation AFTER UPDATE OF generation ON search_index_jobs
    WHEN new.indexKind = 'fts' BEGIN
        UPDATE search_index_state
        SET indexRevision = indexRevision + 1, updatedAt = unixepoch('subsec')
        WHERE indexKind = 'fts';
    END;
    CREATE TRIGGER search_revision_documents_insert AFTER INSERT ON search_documents BEGIN
        UPDATE search_index_state
        SET indexRevision = indexRevision + 1, updatedAt = unixepoch('subsec')
        WHERE indexKind = 'fts';
    END;
    CREATE TRIGGER search_revision_documents_update AFTER UPDATE ON search_documents BEGIN
        UPDATE search_index_state
        SET indexRevision = indexRevision + 1, updatedAt = unixepoch('subsec')
        WHERE indexKind = 'fts';
    END;
    CREATE TRIGGER search_revision_documents_delete AFTER DELETE ON search_documents BEGIN
        UPDATE search_index_state
        SET indexRevision = indexRevision + 1, updatedAt = unixepoch('subsec')
        WHERE indexKind = 'fts';
    END;

    """

    private static let triggerSQL = """
    CREATE TRIGGER search_queue_vaults_delete AFTER DELETE ON vaults BEGIN
        INSERT INTO search_index_jobs(indexKind, targetKind, targetKey, priority, availableAt, updatedAt)
        VALUES('fts', 'vaultCleanup', old.id, 200, unixepoch('subsec'), unixepoch('subsec'))
        ON CONFLICT(indexKind, targetKind, targetKey) DO UPDATE SET
            generation = generation + 1, priority = 200, status = 'pending',
            availableAt = excluded.availableAt, claimedAt = NULL, leaseExpiresAt = NULL,
            lastErrorCode = NULL, updatedAt = excluded.updatedAt;
    END;

    CREATE TRIGGER search_queue_meetings_insert AFTER INSERT ON meetings BEGIN
        INSERT INTO search_index_jobs(indexKind, targetKind, targetKey, availableAt, updatedAt)
        VALUES('fts', 'meeting', new.id, unixepoch('subsec'), unixepoch('subsec'))
        ON CONFLICT(indexKind, targetKind, targetKey) DO UPDATE SET
            generation = generation + 1, priority = max(priority, 10), status = 'pending',
            availableAt = excluded.availableAt, claimedAt = NULL, leaseExpiresAt = NULL,
            lastErrorCode = NULL, updatedAt = excluded.updatedAt;
    END;
    CREATE TRIGGER search_queue_meetings_update
    AFTER UPDATE OF name, description, projectId, calendar_event_ical_uid, calendar_event_recurrence_id,
                    recordingStartedAt, createdAt
    ON meetings BEGIN
        INSERT INTO search_index_jobs(indexKind, targetKind, targetKey, priority, availableAt, updatedAt)
        VALUES('fts', 'meeting', new.id, 10, unixepoch('subsec'), unixepoch('subsec'))
        ON CONFLICT(indexKind, targetKind, targetKey) DO UPDATE SET
            generation = generation + 1, priority = max(priority, 10), status = 'pending',
            availableAt = excluded.availableAt, claimedAt = NULL, leaseExpiresAt = NULL,
            lastErrorCode = NULL, updatedAt = excluded.updatedAt;
    END;
    CREATE TRIGGER search_queue_meetings_delete AFTER DELETE ON meetings BEGIN
        INSERT INTO search_index_jobs(indexKind, targetKind, targetKey, priority, availableAt, updatedAt)
        VALUES('fts', 'meetingCleanup', old.id, 100, unixepoch('subsec'), unixepoch('subsec'))
        ON CONFLICT(indexKind, targetKind, targetKey) DO UPDATE SET
            generation = generation + 1, priority = 100, status = 'pending',
            availableAt = excluded.availableAt, claimedAt = NULL, leaseExpiresAt = NULL,
            lastErrorCode = NULL, updatedAt = excluded.updatedAt;
    END;

    CREATE TRIGGER search_queue_projects_insert AFTER INSERT ON projects BEGIN
        INSERT INTO search_index_jobs(indexKind, targetKind, targetKey, availableAt, updatedAt)
        VALUES('fts', 'project', new.id, unixepoch('subsec'), unixepoch('subsec'))
        ON CONFLICT(indexKind, targetKind, targetKey) DO UPDATE SET
            generation = generation + 1, status = 'pending', availableAt = excluded.availableAt,
            claimedAt = NULL, leaseExpiresAt = NULL, lastErrorCode = NULL, updatedAt = excluded.updatedAt;
    END;
    CREATE TRIGGER search_queue_projects_content_update
    AFTER UPDATE OF description ON projects
    WHEN old.name IS new.name
      AND old.parentProjectId IS new.parentProjectId
      AND old.vaultId IS new.vaultId BEGIN
        INSERT INTO search_index_jobs(indexKind, targetKind, targetKey, availableAt, updatedAt)
        VALUES('fts', 'project', new.id, unixepoch('subsec'), unixepoch('subsec'))
        ON CONFLICT(indexKind, targetKind, targetKey) DO UPDATE SET
            generation = generation + 1, status = 'pending', availableAt = excluded.availableAt,
            claimedAt = NULL, leaseExpiresAt = NULL, lastErrorCode = NULL, updatedAt = excluded.updatedAt;
    END;
    CREATE TRIGGER search_queue_projects_hierarchy_update
    AFTER UPDATE OF name, parentProjectId, vaultId ON projects BEGIN
        INSERT INTO search_index_jobs(indexKind, targetKind, targetKey, availableAt, updatedAt)
        VALUES('fts', 'projectHierarchy', new.id, unixepoch('subsec'), unixepoch('subsec'))
        ON CONFLICT(indexKind, targetKind, targetKey) DO UPDATE SET
            generation = generation + 1, status = 'pending', availableAt = excluded.availableAt,
            claimedAt = NULL, leaseExpiresAt = NULL, lastErrorCode = NULL, updatedAt = excluded.updatedAt;
    END;
    CREATE TRIGGER search_queue_projects_delete AFTER DELETE ON projects BEGIN
        INSERT INTO search_index_jobs(indexKind, targetKind, targetKey, priority, availableAt, updatedAt)
        VALUES('fts', 'projectCleanup', old.id, 100, unixepoch('subsec'), unixepoch('subsec'))
        ON CONFLICT(indexKind, targetKind, targetKey) DO UPDATE SET
            generation = generation + 1, priority = 100, status = 'pending',
            availableAt = excluded.availableAt, claimedAt = NULL, leaseExpiresAt = NULL,
            lastErrorCode = NULL, updatedAt = excluded.updatedAt;
    END;

    CREATE TRIGGER search_queue_meeting_tags_insert AFTER INSERT ON meeting_tags BEGIN
        INSERT INTO search_index_jobs(indexKind, targetKind, targetKey, availableAt, updatedAt)
        VALUES('fts', 'meeting', new.meetingId, unixepoch('subsec'), unixepoch('subsec'))
        ON CONFLICT(indexKind, targetKind, targetKey) DO UPDATE SET
            generation = generation + 1, status = 'pending', availableAt = excluded.availableAt,
            claimedAt = NULL, leaseExpiresAt = NULL, lastErrorCode = NULL, updatedAt = excluded.updatedAt;
    END;
    CREATE TRIGGER search_queue_meeting_tags_delete AFTER DELETE ON meeting_tags BEGIN
        INSERT INTO search_index_jobs(indexKind, targetKind, targetKey, availableAt, updatedAt)
        VALUES('fts', 'meeting', old.meetingId, unixepoch('subsec'), unixepoch('subsec'))
        ON CONFLICT(indexKind, targetKind, targetKey) DO UPDATE SET
            generation = generation + 1, status = 'pending', availableAt = excluded.availableAt,
            claimedAt = NULL, leaseExpiresAt = NULL, lastErrorCode = NULL, updatedAt = excluded.updatedAt;
    END;

    CREATE TRIGGER search_queue_tags_update AFTER UPDATE OF name ON tags BEGIN
        INSERT INTO search_index_jobs(indexKind, targetKind, targetKey, availableAt, updatedAt)
        SELECT 'fts', 'meeting', meetingId, unixepoch('subsec'), unixepoch('subsec')
        FROM meeting_tags WHERE tagId = new.id
        ON CONFLICT(indexKind, targetKind, targetKey) DO UPDATE SET
            generation = generation + 1, status = 'pending', availableAt = excluded.availableAt,
            claimedAt = NULL, leaseExpiresAt = NULL, lastErrorCode = NULL, updatedAt = excluded.updatedAt;
    END;
    CREATE TRIGGER search_queue_tags_delete BEFORE DELETE ON tags BEGIN
        INSERT INTO search_index_jobs(indexKind, targetKind, targetKey, availableAt, updatedAt)
        SELECT 'fts', 'meeting', meetingId, unixepoch('subsec'), unixepoch('subsec')
        FROM meeting_tags WHERE tagId = old.id
        ON CONFLICT(indexKind, targetKind, targetKey) DO UPDATE SET
            generation = generation + 1, status = 'pending', availableAt = excluded.availableAt,
            claimedAt = NULL, leaseExpiresAt = NULL, lastErrorCode = NULL, updatedAt = excluded.updatedAt;
    END;

    CREATE TRIGGER search_queue_calendar_insert AFTER INSERT ON calendar_events BEGIN
        INSERT INTO search_index_jobs(indexKind, targetKind, targetKey, availableAt, updatedAt)
        SELECT 'fts', 'meeting', id, unixepoch('subsec'), unixepoch('subsec') FROM meetings
        WHERE calendar_event_ical_uid = new.ical_uid
          AND calendar_event_recurrence_id = new.recurrence_id
        ON CONFLICT(indexKind, targetKind, targetKey) DO UPDATE SET
            generation = generation + 1, status = 'pending', availableAt = excluded.availableAt,
            claimedAt = NULL, leaseExpiresAt = NULL, lastErrorCode = NULL, updatedAt = excluded.updatedAt;
    END;
    CREATE TRIGGER search_queue_calendar_update
    BEFORE UPDATE OF title, description, ical_uid, recurrence_id ON calendar_events BEGIN
        INSERT INTO search_index_jobs(indexKind, targetKind, targetKey, availableAt, updatedAt)
        SELECT 'fts', 'meeting', id, unixepoch('subsec'), unixepoch('subsec') FROM meetings
        WHERE (calendar_event_ical_uid = old.ical_uid
               AND calendar_event_recurrence_id = old.recurrence_id)
           OR (calendar_event_ical_uid = new.ical_uid
               AND calendar_event_recurrence_id = new.recurrence_id)
        ON CONFLICT(indexKind, targetKind, targetKey) DO UPDATE SET
            generation = generation + 1, status = 'pending', availableAt = excluded.availableAt,
            claimedAt = NULL, leaseExpiresAt = NULL, lastErrorCode = NULL, updatedAt = excluded.updatedAt;
    END;
    CREATE TRIGGER search_queue_calendar_delete BEFORE DELETE ON calendar_events BEGIN
        INSERT INTO search_index_jobs(indexKind, targetKind, targetKey, availableAt, updatedAt)
        SELECT 'fts', 'meeting', id, unixepoch('subsec'), unixepoch('subsec') FROM meetings
        WHERE calendar_event_ical_uid = old.ical_uid
          AND calendar_event_recurrence_id = old.recurrence_id
        ON CONFLICT(indexKind, targetKind, targetKey) DO UPDATE SET
            generation = generation + 1, status = 'pending', availableAt = excluded.availableAt,
            claimedAt = NULL, leaseExpiresAt = NULL, lastErrorCode = NULL, updatedAt = excluded.updatedAt;
    END;
    """
}
