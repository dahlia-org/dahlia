import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct LegacyDatabaseCompatibilityTests {
        @Test
        func openingDatabaseArchivesRetiredTablesAndReconcilesMigrations() async throws {
            let fixture = try LegacyDatabaseFixture()
            defer { fixture.removeFiles() }
            try await fixture.createDatabase(includeBackupMetadata: false)

            let migrated = try AppDatabaseManager(path: fixture.databaseURL.path)
            let result = try await migrated.dbQueue.read { db in
                (
                    organizationColumns: try db.columns(in: "organizations").map(\.name),
                    archivedOrganizationName: try String.fetchOne(
                        db,
                        sql: "SELECT name FROM legacy_retired_organizations WHERE id = 'legacy-org'"
                    ),
                    archivedLakebaseValue: try String.fetchOne(
                        db,
                        sql: "SELECT value FROM legacy_retired_lakebase_connections WHERE id = 1"
                    ),
                    appliedIdentifiers: try AppDatabaseManager.migrator.appliedIdentifiers(db),
                    hasExpectedSchema: try AppDatabaseManager.hasExpectedCurrentSchema(db)
                )
            }

            #expect(result.organizationColumns.contains("vaultId"))
            #expect(result.archivedOrganizationName == "Legacy organization")
            #expect(result.archivedLakebaseValue == "Preserved Lakebase setting")
            #expect(result.appliedIdentifiers.contains(AppDatabaseManager.currentMigrationIdentifier))
            #expect(result.appliedIdentifiers.isDisjoint(with: LegacyDatabaseCompatibility.retiredMigrationIdentifiers))
            #expect(result.hasExpectedSchema)

            let contact = ContactRecord(
                id: .v7(),
                vaultId: fixture.vault.id,
                email: "retained@example.com",
                displayName: "Retained contact",
                createdAt: .now,
                updatedAt: .now
            )
            try await migrated.dbQueue.write { db in
                try contact.insert(db)
                try MeetingParticipantRecord(
                    meetingId: fixture.meetingID,
                    contactId: contact.id,
                    role: .attendee,
                    responseStatus: .accepted,
                    source: "test",
                    createdAt: .now,
                    updatedAt: .now
                ).insert(db)
            }
            let repository = MeetingRepository(dbQueue: migrated.dbQueue)
            try repository.deleteMeeting(id: fixture.meetingID)
            let deletionResult = try await migrated.dbQueue.read { db in
                (
                    meetingCount: try MeetingRecord.fetchCount(db),
                    archivedParticipantCount: try Int.fetchOne(
                        db,
                        sql: "SELECT COUNT(*) FROM legacy_retired_meeting_participants"
                    ),
                    archivedParticipantForeignKeyCount: try db.foreignKeys(
                        on: "legacy_retired_meeting_participants"
                    ).count,
                    contactCount: try ContactRecord.filter(key: contact.id).fetchCount(db),
                    participantCount: try MeetingParticipantRecord.fetchCount(db)
                )
            }
            #expect(deletionResult.meetingCount == 0)
            #expect(deletionResult.archivedParticipantCount == 1)
            #expect(deletionResult.archivedParticipantForeignKeyCount == 0)
            #expect(deletionResult.contactCount == 1)
            #expect(deletionResult.participantCount == 0)
        }

        @Test
        func restoreAcceptsRetiredProductionSchemaAndPreservesCoreData() async throws {
            let fixture = try LegacyDatabaseFixture()
            defer { fixture.removeFiles() }
            try await fixture.createDatabase(includeBackupMetadata: true)

            let liveURL = fixture.rootURL.appending(path: "live.sqlite")
            let live = try AppDatabaseManager(path: liveURL.path)
            let service = BackupService(
                dbQueue: live.dbQueue,
                applicationSupportURL: fixture.rootURL
            )

            let imported = try await service.importGeneration(from: fixture.databaseURL)
            let marker = try await service.prepareRestore(from: imported)
            let stagedURL = fixture.rootURL
                .appending(path: BackupService.restoreDirectoryName)
                .appending(path: marker.stagedFilename)
            let staged = try DatabaseQueue(path: stagedURL.path)
            let result = try await staged.read { db in
                (
                    vaultName: try String.fetchOne(
                        db,
                        sql: "SELECT name FROM vaults WHERE id = ?",
                        arguments: [fixture.vault.id]
                    ),
                    archivedOrganizationName: try String.fetchOne(
                        db,
                        sql: "SELECT name FROM legacy_retired_organizations WHERE id = 'legacy-org'"
                    ),
                    appliedIdentifiers: try AppDatabaseManager.migrator.appliedIdentifiers(db),
                    hasExpectedSchema: try AppDatabaseManager.hasExpectedCurrentSchema(db)
                )
            }

            #expect(result.vaultName == fixture.vault.name)
            #expect(result.archivedOrganizationName == "Legacy organization")
            #expect(result.appliedIdentifiers.isDisjoint(with: LegacyDatabaseCompatibility.retiredMigrationIdentifiers))
            #expect(result.hasExpectedSchema)
        }
    }

    private struct LegacyDatabaseFixture {
        let rootURL: URL
        let databaseURL: URL
        let vault: VaultRecord
        let meetingID: UUID
        let personID: UUID

        init() throws {
            rootURL = FileManager.default.temporaryDirectory
                .appending(path: "dahlia-retired-schema-\(UUID.v7().uuidString)", directoryHint: .isDirectory)
            databaseURL = rootURL.appending(path: "legacy.sqlite")
            meetingID = .v7()
            personID = .v7()
            vault = VaultRecord(
                id: .v7(),
                path: rootURL.appending(path: "Vault").path,
                name: "Preserved production vault",
                createdAt: .now,
                lastOpenedAt: .now
            )
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        }

        func createDatabase(includeBackupMetadata: Bool) async throws {
            let queue = try DatabaseQueue(path: databaseURL.path)
            try AppDatabaseManager.migrator.migrate(queue, upTo: "v24_projectWorkspaceHierarchy")
            try await queue.write { db in
                try vault.insert(db)
                try db.execute(
                    sql: """
                    CREATE TABLE organizations (
                        id TEXT PRIMARY KEY NOT NULL,
                        name TEXT NOT NULL
                    );
                    CREATE TABLE people (
                        id BLOB PRIMARY KEY NOT NULL,
                        display_name TEXT NOT NULL
                    );
                    CREATE TABLE meeting_participants (
                        id BLOB PRIMARY KEY NOT NULL,
                        meeting_id BLOB NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                        person_id BLOB REFERENCES people(id) ON DELETE SET NULL
                    );
                    CREATE TABLE lakebase_connections (
                        id INTEGER PRIMARY KEY NOT NULL,
                        value TEXT NOT NULL
                    );
                    INSERT INTO organizations (id, name)
                    VALUES ('legacy-org', 'Legacy organization');
                    INSERT INTO people (id, display_name)
                    VALUES ('legacy-person', 'Legacy person');
                    INSERT INTO lakebase_connections (id, value)
                    VALUES (1, 'Preserved Lakebase setting');
                    """
                )
                try replaceTranscriptSegmentsWithReleasedLayout(in: db)
                try MeetingRecord(
                    id: meetingID,
                    vaultId: vault.id,
                    projectId: nil,
                    name: "Legacy meeting",
                    createdAt: .now,
                    updatedAt: .now
                ).insert(db)
                try db.execute(
                    sql: """
                    INSERT INTO people (id, display_name)
                    VALUES (?, 'Legacy person');
                    INSERT INTO meeting_participants (id, meeting_id, person_id)
                    VALUES (?, ?, ?);
                    """,
                    arguments: [personID, UUID.v7(), meetingID, personID]
                )
                for identifier in LegacyDatabaseCompatibility.retiredMigrationIdentifiers {
                    try db.execute(
                        sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)",
                        arguments: [identifier]
                    )
                }
                if includeBackupMetadata {
                    try insertBackupMetadata(in: db)
                }
            }
            try queue.close()
        }

        func removeFiles() {
            try? FileManager.default.removeItem(at: rootURL)
        }

        private func insertBackupMetadata(in db: Database) throws {
            try db.execute(
                sql: """
                CREATE TABLE dahlia_backup_metadata (
                    formatVersion INTEGER NOT NULL,
                    generationId TEXT NOT NULL,
                    createdAt DATETIME NOT NULL,
                    schemaVersion INTEGER NOT NULL,
                    migrationIdentifier TEXT NOT NULL,
                    appVersion TEXT NOT NULL,
                    appBuild TEXT NOT NULL,
                    reason TEXT NOT NULL
                );
                INSERT INTO dahlia_backup_metadata (
                    formatVersion, generationId, createdAt, schemaVersion,
                    migrationIdentifier, appVersion, appBuild, reason
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?);
                """,
                arguments: [
                    BackupMetadata.currentFormatVersion,
                    UUID.v7().uuidString,
                    Date.now,
                    24,
                    "v24_projectWorkspaceHierarchy",
                    "0.6.5",
                    "33",
                    BackupMetadata.Reason.manual.rawValue,
                ]
            )
        }

        private func replaceTranscriptSegmentsWithReleasedLayout(in db: Database) throws {
            try db.execute(
                sql: """
                DROP TABLE transcript_segments;
                CREATE TABLE transcript_segments (
                    id BLOB PRIMARY KEY NOT NULL,
                    meetingId BLOB NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                    startTime DATETIME NOT NULL,
                    endTime DATETIME,
                    text TEXT NOT NULL,
                    isConfirmed BOOLEAN NOT NULL DEFAULT 0,
                    speakerLabel TEXT,
                    translatedText TEXT,
                    sessionId BLOB
                );
                """
            )
            try db.create(
                index: "transcript_segments_on_meetingId",
                on: "transcript_segments",
                columns: ["meetingId"]
            )
            try db.create(
                index: "transcript_segments_on_meetingId_startTime",
                on: "transcript_segments",
                columns: ["meetingId", "startTime"]
            )
            try db.execute(
                sql: """
                CREATE INDEX transcript_segments_on_meetingId_isConfirmed_startTime_id
                ON transcript_segments(meetingId, isConfirmed, startTime, id)
                """
            )
        }
    }
#endif
