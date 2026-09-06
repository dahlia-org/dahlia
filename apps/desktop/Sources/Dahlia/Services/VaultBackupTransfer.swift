import DahliaRuntimeSupport
import Foundation
import GRDB

/// Copies only portable vault content into a trusted current-schema database.
/// Keep this list explicit: adding a table must not silently export accounts or runtime state.
enum VaultBackupTransfer {
    static let vaultTables = [
        "projects", "organizations", "contacts", "instructions", "insights", "conversation_topics",
    ]
    static let meetingTables = [
        "recording_sessions", "transcript_segments", "notes", "screenshots", "summaries", "action_items",
        "summary_exports", "meeting_conversation_metrics", "meeting_conversation_source_metrics", "meeting_tags",
        "meeting_participants",
    ]
    static let referenceTables = [
        "organization_domains": ("organizationId", "organizations"),
        "organization_memberships": ("organizationId", "organizations"),
        "project_resource_references": ("projectId", "projects"),
        "insight_references": ("insightId", "insights"),
        "conversation_topic_references": ("topicId", "conversation_topics"),
    ]
    private static let references = [
        "vaultId": "vaults", "projectId": "projects", "parentProjectId": "projects",
        "meetingId": "meetings", "sessionId": "recording_sessions", "recordingSessionId": "recording_sessions",
        "organizationId": "organizations", "parentOrganizationId": "organizations", "contactId": "contacts",
        "insightId": "insights", "topicId": "conversation_topics", "tagId": "tags",
    ]

    static func copy(
        vaultId: UUID,
        in db: Database,
        destinationVault: VaultRecord,
        remapIDs: Bool
    ) throws {
        guard try VaultRecord.fetchOne(db, sql: "SELECT * FROM backup_source.vaults WHERE id = ?", arguments: [vaultId]) != nil
        else { throw BackupServiceError.invalidBackup }
        try destinationVault.insert(db)
        var mappings: [String: [DatabaseValue: DatabaseValue]] = [
            "vaults": [vaultId.databaseValue: destinationVault.id.databaseValue],
        ]
        let tables = vaultTables + ["meetings"] + meetingTables + referenceTables.keys.sorted()
        if remapIDs {
            for table in tables where try db.columns(in: table).contains(where: { $0.name == "id" && $0.type == "BLOB" }) {
                let ids = try UUID.fetchAll(db, sql: "SELECT id FROM backup_source.\(table) WHERE \(predicate(table))", arguments: [vaultId])
                mappings[table] = Dictionary(uniqueKeysWithValues: ids.map { ($0.databaseValue, UUID.v7().databaseValue) })
            }
        }
        try copyTags(vaultId: vaultId, in: db, mappings: &mappings)
        try copyCalendar(vaultId: vaultId, in: db)
        for table in tables {
            let sql: String
            if table == "projects" || table == "organizations" {
                let parent = table == "projects" ? "parentProjectId" : "parentOrganizationId"
                sql = """
                WITH RECURSIVE hierarchy(id, depth) AS (
                    SELECT id, 0 FROM backup_source.\(table) WHERE vaultId = ? AND \(parent) IS NULL
                    UNION ALL
                    SELECT child.id, hierarchy.depth + 1 FROM backup_source.\(table) child
                    JOIN hierarchy ON child.\(parent) = hierarchy.id
                ) SELECT content.* FROM backup_source.\(table) content JOIN hierarchy ON content.id = hierarchy.id ORDER BY depth
                """
            } else {
                // Insert the primary domain first so the default-primary trigger cannot promote another domain.
                let order = table == "organization_domains" ? " ORDER BY isPrimary DESC" : ""
                sql = "SELECT * FROM backup_source.\(table) WHERE \(predicate(table))\(order)"
            }
            let rows = try Row.fetchCursor(db, sql: sql, arguments: [vaultId])
            var copiedCount = 0
            while let row = try rows.next() {
                // New vaults do not inherit export destinations; local output files are never included.
                if table == "summary_exports", remapIDs || row["type"] as String == "vault" { continue }
                let columns = Array(row.columnNames)
                let values = try columns.map { column -> DatabaseValue in
                    let value: DatabaseValue = row[column]
                    if value.isNull { return value }
                    if remapIDs, table == "summaries", column == "document" {
                        return try remapSummary(row["document"], screenshots: mappings["screenshots"] ?? [:]).databaseValue
                    }
                    let referencedTable: String? = if column == "id" {
                        table
                    } else if column == "resourceId" {
                        [
                            "organization": "organizations",
                            "contact": "contacts",
                            "project": "projects",
                            "meeting": "meetings",
                        ][row["resourceType"] as String]
                    } else {
                        references[column]
                    }
                    if let referencedTable, let mapping = mappings[referencedTable] {
                        guard let mapped = mapping[value] else { throw BackupServiceError.invalidBackup }
                        return mapped
                    }
                    return value
                }
                try insert(columns: columns, values: values, table: table, into: db)
                copiedCount += 1
            }
            if table == "projects" || table == "organizations" {
                let expected = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM backup_source.\(table) WHERE vaultId = ?", arguments: [vaultId])
                guard expected == copiedCount else { throw BackupServiceError.invalidBackup }
            }
        }
        // Relationship triggers update revisions; a restored snapshot retains the saved values.
        for table in ["projects", "organizations", "contacts", "insights", "conversation_topics"] {
            let timestampColumn = table == "projects" ? "" : ", updatedAt"
            let rows = try Row.fetchCursor(
                db,
                sql: "SELECT id, revision\(timestampColumn) FROM backup_source.\(table) WHERE vaultId = ?",
                arguments: [vaultId]
            )
            while let row = try rows.next() {
                let original: DatabaseValue = row["id"]
                let id = mappings[table]?[original] ?? original
                var arguments: StatementArguments = [row["revision"] as DatabaseValue]
                var assignment = "revision = ?"
                if table != "projects" {
                    assignment += ", updatedAt = ?"
                    arguments += [row["updatedAt"] as DatabaseValue]
                }
                arguments += [id]
                try db.execute(sql: "UPDATE \(table) SET \(assignment) WHERE id = ?", arguments: arguments)
            }
        }
    }

    private static func remapSummary(_ json: String, screenshots: [DatabaseValue: DatabaseValue]) throws -> String {
        var document = try SummaryDocument.decode(databaseJSON: json)
        for sectionIndex in document.sections.indices {
            document.sections[sectionIndex].id = .v7()
            for blockIndex in document.sections[sectionIndex].blocks.indices {
                var block = document.sections[sectionIndex].blocks[blockIndex]
                block.id = .v7()
                if case let .image(id, caption) = block.content {
                    guard let value = screenshots[id.databaseValue], let mapped = UUID.fromDatabaseValue(value) else {
                        throw BackupServiceError.invalidBackup
                    }
                    block.content = .image(screenshotId: mapped, caption: caption)
                }
                document.sections[sectionIndex].blocks[blockIndex] = block
            }
        }
        return try document.databaseJSONString()
    }

    static func portableVault(_ vault: VaultRecord) -> VaultRecord {
        var result = vault
        result.path = nil
        result.accountConnectionId = nil
        result.syncRole = nil
        result.syncConfirmedConnectionId = nil
        result.syncPullCursor = nil
        result.syncLastCommittedCursor = nil
        result.syncRecoveryState = nil
        result.databricksProfile = ""
        return result
    }

    static func removeVaultContent(id: UUID, in db: Database) throws {
        let projects = try ProjectRecord.fetchResolvedAll(vaultId: id, in: db)
            .sorted { $0.path.split(separator: "/").count > $1.path.split(separator: "/").count }
        for project in projects {
            _ = try ProjectRecord.deleteOne(db, key: project.id)
        }
        // Organization parents use a deferred FK; all rows are removed in the same transaction.
        try db.execute(sql: "PRAGMA defer_foreign_keys = ON")
        _ = try VaultRecord.deleteOne(db, key: id)
        try db.execute(sql: "DELETE FROM sync_entity_state WHERE vaultId = ?", arguments: [id])
    }

    static func validateLocalTarget(id: UUID, in db: Database) throws -> VaultRecord {
        guard let vault = try VaultRecord.fetchOne(db, key: id),
              vault.accountConnectionId == nil, vault.syncRole == nil,
              vault.syncConfirmedConnectionId == nil,
              try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM sync_transactions WHERE vaultId = ?)", arguments: [id]) == false else {
            throw BackupServiceError.restoreTargetUnavailable
        }
        return vault
    }

    static func validateIntegrity(in db: Database) throws {
        let result = try String.fetchOne(db, sql: "PRAGMA quick_check") ?? "unknown"
        guard result == "ok", try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty else {
            throw BackupServiceError.integrityCheckFailed(result)
        }
    }

    private static func predicate(_ table: String) -> String {
        if vaultTables.contains(table) || table == "meetings" { return "vaultId = ?" }
        if meetingTables.contains(table) { return "meetingId IN (SELECT id FROM backup_source.meetings WHERE vaultId = ?)" }
        let (column, parent) = referenceTables[table]!
        return "\(column) IN (SELECT id FROM backup_source.\(parent) WHERE vaultId = ?)"
    }

    private static func copyTags(
        vaultId: UUID,
        in db: Database,
        mappings: inout [String: [DatabaseValue: DatabaseValue]]
    ) throws {
        let rows = try Row.fetchCursor(db, sql: """
        SELECT * FROM backup_source.tags WHERE id IN (
            SELECT tagId FROM backup_source.meeting_tags JOIN backup_source.meetings ON meetings.id = meeting_tags.meetingId WHERE vaultId = ?
        )
        """, arguments: [vaultId])
        mappings["tags"] = [:]
        while let row = try rows.next() {
            let name: String = row["name"]
            let id: Int64
            if let existing = try Int64.fetchOne(db, sql: "SELECT id FROM tags WHERE name = ?", arguments: [name]) {
                id = existing
            } else {
                let columns = Array(row.columnNames).filter { $0 != "id" }
                try insert(columns: columns, values: columns.map { row[$0] as DatabaseValue }, table: "tags", into: db)
                id = db.lastInsertedRowID
            }
            mappings["tags"]?[row["id"] as DatabaseValue] = id.databaseValue
        }
    }

    private static func copyCalendar(vaultId: UUID, in db: Database) throws {
        for table in ["calendar_events", "calendar_event_sources"] {
            let rows = try Row.fetchCursor(db, sql: """
            SELECT * FROM backup_source.\(table) WHERE EXISTS (
                SELECT 1 FROM backup_source.meetings WHERE vaultId = ?
                AND calendar_event_ical_uid = \(table).ical_uid
                AND calendar_event_recurrence_id = \(table).recurrence_id
            )
            """, arguments: [vaultId])
            while let row = try rows.next() {
                let columns = Array(row.columnNames)
                try insert(
                    columns: columns,
                    values: columns.map { row[$0] as DatabaseValue },
                    table: table,
                    into: db,
                    onConflict: " ON CONFLICT DO NOTHING"
                )
            }
        }
    }

    private static func insert(
        columns: [String], values: [DatabaseValue], table: String, into db: Database, onConflict: String = ""
    ) throws {
        let names = columns.map { "\"\($0)\"" }.joined(separator: ", ")
        let placeholders = columns.map { _ in "?" }.joined(separator: ", ")
        try db.execute(
            sql: "INSERT INTO \(table) (\(names)) VALUES (\(placeholders))\(onConflict)",
            arguments: StatementArguments(values)
        )
    }
}
