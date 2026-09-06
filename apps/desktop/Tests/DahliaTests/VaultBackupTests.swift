import DahliaRuntimeSupport
import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct VaultBackupTests {
        @Test(arguments: [VaultBackupRestoreRequest.Mode.overwrite, .newVault])
        func restoresOnlySelectedVault(mode: VaultBackupRestoreRequest.Mode) async throws {
            let fixture = try BatchAudioTestFixture(name: "VaultRestore", endedAt: .now, batchCompletedAt: .now)
            defer { fixture.removeFiles() }
            try await fixture.recordMicrophoneAudio()
            let retainedSegments = try await fixture.database.dbQueue.read { try RecordingAudioSegmentRecord.fetchAll($0) }
            try await fixture.database.dbQueue.write { db in
                try db.execute(sql: """
                INSERT INTO recording_audio_reconciliation_issues
                    (id, recordingSessionId, audioSegmentId, relativePath, reason, firstObservedAt, lastObservedAt)
                SELECT ?, recordingSessionId, id, finalRelativePath, 'test', ?, ? FROM recording_audio_segments
                """, arguments: [UUID.v7(), fixture.now, fixture.now])
            }
            try seedRelationships(fixture)
            let other = VaultRecord(id: .v7(), path: nil, name: "Other", createdAt: .now, lastOpenedAt: .now)
            let connection = DahliaAccountConnectionRecord(id: .v7(), origin: "https://example.invalid", clientID: "test", createdAt: .now)
            try await fixture.database.dbQueue.write { db in
                try connection.insert(db)
                var synced = other
                synced.accountConnectionId = connection.id
                synced.syncRole = "owner"
                synced.syncPullCursor = "keep-cursor"
                try synced.insert(db)
                if mode == .newVault {
                    try db.execute(
                        sql: "UPDATE vaults SET accountConnectionId = ?, syncConfirmedConnectionId = ?, syncRole = 'member', syncPullCursor = 'member-cursor' WHERE id = ?",
                        arguments: [connection.id, connection.id, fixture.meeting.vaultId]
                    )
                }
                try db.execute(
                    sql: "INSERT INTO sync_transactions(id, vaultId, connectionId, createdAt, availableAt) VALUES (?, ?, ?, ?, ?)",
                    arguments: [UUID.v7(), other.id, connection.id, Date(), Date()]
                )
            }
            let service = BackupService(dbQueue: fixture.database.dbQueue, applicationSupportURL: fixture.testRootURL)
            let generation = try await service.createGeneration(vaultIds: [fixture.meeting.vaultId])
            try verifyExport(generation, fixture: fixture)
            let databaseURL = fixture.testRootURL.appending(path: "live.sqlite")
            let live = try AppDatabaseManager(path: databaseURL.path, enablesConcurrentSearch: true)
            try fixture.database.dbQueue.backup(to: live.dbQueue)
            try await live.dbQueue.write { db in
                try db.execute(sql: "UPDATE meetings SET name = 'Changed' WHERE id = ?", arguments: [fixture.meeting.id])
                try db.execute(sql: "UPDATE vaults SET name = 'Other changed after backup' WHERE id = ?", arguments: [other.id])
            }
            try live.close()
            let audioURL = fixture.testRootURL.appending(path: "BatchAudio/audio.caf")
            try FileManager.default.createDirectory(at: audioURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("keep audio".utf8).write(to: audioURL)
            let targetID = mode == .overwrite ? fixture.meeting.vaultId : UUID.v7()
            let request = VaultBackupRestoreRequest(
                sourceVaultId: fixture.meeting.vaultId,
                targetVaultId: targetID,
                mode: mode,
                name: "Restored"
            )
            let marker = try await service.prepareRestore(from: generation, requests: [request])
            let decoded = try JSONDecoder.backupDecoder.decode(
                PendingDatabaseRestore.self,
                from: Data(contentsOf: BackupService.pendingRestoreURL(applicationSupportURL: fixture.testRootURL))
            )
            #expect(decoded == marker)
            let lateWriter = try AppDatabaseManager(path: databaseURL.path)
            try await lateWriter.dbQueue.write { db in
                try db.execute(sql: "UPDATE vaults SET name = 'Other changed after preparation' WHERE id = ?", arguments: [other.id])
            }
            try lateWriter.close()
            let outcome = BackupRestoreStartupProcessor.applyPendingRestore(applicationSupportURL: fixture.testRootURL, databaseURL: databaseURL)
            guard case .restored = outcome else { Issue.record("Restore failed: \(outcome)")
                return
            }
            let result = try AppDatabaseManager(path: databaseURL.path)
            defer { try? result.close() }
            try await result.dbQueue.read { db throws in
                #expect(try VaultRecord.fetchCount(db) == (mode == .overwrite ? 2 : 3))
                #expect(try VaultRecord.fetchOne(db, key: other.id)?.name == "Other changed after preparation")
                #expect(try VaultRecord.fetchOne(db, key: other.id)?.syncPullCursor == "keep-cursor")
                #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_transactions") == 1)
                let vault = try #require(try VaultRecord.fetchOne(db, key: targetID))
                #expect(vault.accountConnectionId == nil)
                #expect(vault.path == (mode == .overwrite ? fixture.vaultURL.path : nil))
                let meeting = try #require(try MeetingRecord.filter(Column("vaultId") == targetID).fetchOne(db))
                #expect(meeting.name == fixture.meeting.name)
                #expect((meeting.id == fixture.meeting.id) == (mode == .overwrite))
                let session = try #require(try RecordingSessionRecord.filter(Column("meetingId") == meeting.id).fetchOne(db))
                #expect(try RecordingAudioSegmentRecord.filter(Column("recordingSessionId") == session.id).fetchCount(db)
                    == (mode == .overwrite ? 1 : 0))
                #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM recording_audio_segment_ranges") == 1)
                #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM recording_audio_source_progress") == 1)
                #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM recording_audio_reconciliation_issues") == 1)
                #expect(try RecordingAudioSegmentRecord.fetchAll(db) == retainedSegments)
                let screenshot = try #require(try MeetingScreenshotRecord.filter(Column("meetingId") == meeting.id).fetchOne(db))
                let summary = try #require(try SummaryRecord.fetchOne(db, key: meeting.id))
                #expect(try summary.loadDocument().referencedScreenshotIds == [screenshot.id])
                #expect(try SummaryExportRecord.filter(Column("meetingId") == meeting.id).fetchCount(db) == (mode == .overwrite ? 1 : 0))
                #expect(screenshot.imageData == Data([1, 2, 3]))
                let projects = try ProjectRecord.fetchResolvedAll(vaultId: targetID, in: db)
                #expect(Set(projects.map(\.path)) == ["Parent", "Parent/Child"])
                #expect(try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM conversation_topic_references JOIN conversation_topics ON id = topicId WHERE vaultId = ?",
                    arguments: [targetID]
                ) == 1)
                let organizations = try OrganizationRecord.filter(Column("vaultId") == targetID).fetchAll(db)
                #expect(organizations.count == 2)
                let childOrganization = try #require(organizations.first { $0.nodeKind == .unit })
                #expect(organizations.contains { $0.id == childOrganization.parentOrganizationId })
                #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM organization_domains WHERE vaultId = ?", arguments: [targetID]) == 2)
                #expect(try String.fetchOne(
                    db,
                    sql: "SELECT domainName FROM organization_domains WHERE vaultId = ? AND isPrimary = 1",
                    arguments: [targetID]
                ) == "example.invalid")
                #expect(try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM project_resource_references r JOIN contacts c ON c.id = r.resourceId JOIN projects p ON p.id = r.projectId WHERE c.vaultId = ? AND p.vaultId = ?",
                    arguments: [targetID, targetID]
                ) == 1)
                try VaultBackupTransfer.validateIntegrity(in: db)
            }
            #expect(try Data(contentsOf: audioURL) == Data("keep audio".utf8))
            let generations = try await service.listGenerations()
            #expect(generations.filter { $0.metadata?.reason == .beforeRestore }.count == (mode == .overwrite ? 1 : 0))
            await result.searchIndexer.drain()
            let indexedCount = try await result.dbQueue.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM search_documents WHERE vaultId = ?", arguments: [targetID]) ?? 0
            }
            #expect(indexedCount > 0)
        }

        @Test
        func repeatedNewRestoreUsesDistinctIDsAndPreservesSharedTags() async throws {
            let fixture = try BatchAudioTestFixture(name: "RepeatedRestore", endedAt: .now, batchCompletedAt: .now)
            defer { fixture.removeFiles() }
            try seedRelationships(fixture)
            let service = BackupService(dbQueue: fixture.database.dbQueue, applicationSupportURL: fixture.testRootURL)
            let generation = try await service.createGeneration(vaultIds: [fixture.meeting.vaultId])
            let databaseURL = fixture.testRootURL.appending(path: "live.sqlite")
            let live = try AppDatabaseManager(path: databaseURL.path, enablesConcurrentSearch: true)
            try fixture.database.dbQueue.backup(to: live.dbQueue)
            try await live.dbQueue.write { try $0.execute(sql: "UPDATE tags SET colorHex = '#ffffff'") }
            try live.close()
            for _ in 0 ..< 2 {
                _ = try await service.prepareRestore(from: generation, requests: [VaultBackupRestoreRequest(
                    sourceVaultId: fixture.meeting.vaultId, targetVaultId: .v7(), mode: .newVault, name: "Same name"
                )])
                let outcome = BackupRestoreStartupProcessor.applyPendingRestore(applicationSupportURL: fixture.testRootURL, databaseURL: databaseURL)
                guard case .restored = outcome else { Issue.record("Restore failed: \(outcome)")
                    return
                }
            }
            let result = try AppDatabaseManager(path: databaseURL.path)
            defer { try? result.close() }
            try await result.dbQueue.read { db throws in
                #expect(try VaultRecord.fetchCount(db) == 3)
                #expect(try MeetingRecord.fetchCount(db) == 3)
                #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tags") == 1)
                #expect(try String.fetchOne(db, sql: "SELECT colorHex FROM tags") == "#ffffff")
                #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM meeting_tags") == 3)
                try VaultBackupTransfer.validateIntegrity(in: db)
            }
        }

        @Test
        func rejectsSyncedOrMissingOverwriteTarget() async throws {
            let fixture = try BatchAudioTestFixture(name: "RestoreTarget")
            defer { fixture.removeFiles() }
            let service = BackupService(dbQueue: fixture.database.dbQueue, applicationSupportURL: fixture.testRootURL)
            let generation = try await service.createGeneration(vaultIds: [fixture.meeting.vaultId])
            let request = VaultBackupRestoreRequest(
                sourceVaultId: fixture.meeting.vaultId,
                targetVaultId: fixture.meeting.vaultId,
                mode: .overwrite,
                name: "Test"
            )
            try await fixture.database.dbQueue.write { db in
                try db.execute(sql: "UPDATE vaults SET syncRole = 'owner'")
            }
            await #expect(throws: BackupServiceError.restoreTargetUnavailable) { try await service.prepareRestore(
                from: generation,
                requests: [request]
            )
            }
            _ = try await fixture.database.dbQueue.write { try VaultRecord.deleteAll($0) }
            await #expect(throws: BackupServiceError.restoreTargetUnavailable) { try await service.prepareRestore(
                from: generation,
                requests: [request]
            )
            }
        }

        @Test
        func safetyBackupFailureLeavesLiveDatabaseIntact() async throws {
            let fixture = try BatchAudioTestFixture(name: "SafetyFailure")
            defer { fixture.removeFiles() }
            let service = BackupService(dbQueue: fixture.database.dbQueue, applicationSupportURL: fixture.testRootURL)
            let generation = try await service.createGeneration(vaultIds: [fixture.meeting.vaultId])
            _ = try await service.prepareRestore(from: generation, requests: [VaultBackupRestoreRequest(
                sourceVaultId: fixture.meeting.vaultId, targetVaultId: fixture.meeting.vaultId, mode: .overwrite, name: "Test"
            )])
            let databaseURL = fixture.testRootURL.appending(path: "live.sqlite")
            let live = try AppDatabaseManager(path: databaseURL.path, enablesConcurrentSearch: true)
            try fixture.database.dbQueue.backup(to: live.dbQueue)
            try await live.dbQueue.write { try $0.execute(sql: "UPDATE meetings SET name = 'Keep this'") }
            try live.close()
            let backupDirectory = fixture.testRootURL.appending(path: BackupService.backupDirectoryName)
            try FileManager.default.removeItem(at: backupDirectory)
            try Data("blocks directory creation".utf8).write(to: backupDirectory)
            let outcome = BackupRestoreStartupProcessor.applyPendingRestore(applicationSupportURL: fixture.testRootURL, databaseURL: databaseURL)
            guard case .failed = outcome else { Issue.record("Expected safety failure")
                return
            }
            let result = try AppDatabaseManager(path: databaseURL.path)
            defer { try? result.close() }
            #expect(try await result.dbQueue.read { try MeetingRecord.fetchOne($0, key: fixture.meeting.id)?.name } == "Keep this")
        }

        @Test
        func settingsSelectionEmptyErrorAndOverwriteAvailability() async throws {
            let fixture = try BatchAudioTestFixture(name: "BackupSettings")
            defer { fixture.removeFiles() }
            let unavailable = BackupSettingsViewModel(dbQueue: nil, applicationSupportURL: fixture.testRootURL)
            await unavailable.refresh()
            #expect(unavailable.vaults.isEmpty)
            #expect(unavailable.selectedVaultIds.isEmpty)
            let model = BackupSettingsViewModel(dbQueue: fixture.database.dbQueue, applicationSupportURL: fixture.testRootURL)
            model.selectedVaultIds = [fixture.meeting.vaultId]
            await model.refresh()
            #expect(model.generations.isEmpty)
            #expect(model.selectedVaultIds == [fixture.meeting.vaultId])
            await model.createBackup()
            let metadata = try #require(model.generations.first?.metadata)
            #expect(model.canOverwrite(vaultId: metadata.vaults[0].id))
            #expect(!model.isBusy)
            try await fixture.database.dbQueue.write { try $0.execute(sql: "UPDATE vaults SET syncRole = 'owner'") }
            await model.refresh()
            #expect(!model.canOverwrite(vaultId: metadata.vaults[0].id))
            await model.importBackup(from: fixture.testRootURL.appending(path: "missing.sqlite"))
            #expect(model.errorMessage != nil)
            #expect(!model.isBusy)
        }

        @Test
        func corruptHierarchyCannotSilentlyOmitProjects() async throws {
            let fixture = try BatchAudioTestFixture(name: "CorruptHierarchy")
            defer { fixture.removeFiles() }
            let parent = ProjectRecord(id: .v7(), vaultId: fixture.meeting.vaultId, path: "Parent", createdAt: .now)
            let child = ProjectRecord(
                id: .v7(),
                vaultId: fixture.meeting.vaultId,
                parentProjectId: parent.id,
                name: "Child",
                createdAt: .now,
                projectType: nil
            )
            try await fixture.database.dbQueue.write { db in
                try parent.insert(db)
                try child.insert(db)
            }
            let service = BackupService(dbQueue: fixture.database.dbQueue, applicationSupportURL: fixture.testRootURL)
            let generation = try await service.createGeneration(vaultIds: [fixture.meeting.vaultId])
            let editable = try DatabaseQueue(path: generation.fileURL.path, configuration: AppDatabaseManager.configuration())
            try await editable.write { db in
                let trigger = try String.fetchOne(db, sql: "SELECT sql FROM sqlite_master WHERE name = 'projects_validate_parent_update'")!
                try db.execute(sql: "DROP TRIGGER projects_validate_parent_update")
                try db.execute(sql: "UPDATE projects SET parentProjectId = ? WHERE id = ?", arguments: [UUID.v7(), child.id])
                try db.execute(sql: trigger)
            }
            try editable.close()
            _ = try await service.prepareRestore(from: generation, requests: [VaultBackupRestoreRequest(
                sourceVaultId: fixture.meeting.vaultId, targetVaultId: .v7(), mode: .newVault, name: "New"
            )])
            let databaseURL = fixture.testRootURL.appending(path: "live.sqlite")
            let live = try AppDatabaseManager(path: databaseURL.path)
            try fixture.database.dbQueue.backup(to: live.dbQueue)
            try live.close()
            let outcome = BackupRestoreStartupProcessor.applyPendingRestore(applicationSupportURL: fixture.testRootURL, databaseURL: databaseURL)
            guard case .failed = outcome else { Issue.record("Invalid hierarchy must fail, not omit rows")
                return
            }
            let result = try AppDatabaseManager(path: databaseURL.path)
            defer { try? result.close() }
            let counts = try await result.dbQueue.read { db in try (VaultRecord.fetchCount(db), ProjectRecord.fetchCount(db)) }
            #expect(counts.0 == 1)
            #expect(counts.1 == 2)
        }

        @Test(arguments: [VaultBackupRestoreRequest.Mode.overwrite, .newVault], [2, 3])
        func restoresKnownOlderSchemaWithoutChangingOriginal(mode: VaultBackupRestoreRequest.Mode, format: Int) async throws {
            let fixture = try BatchAudioTestFixture(name: "OlderV2", endedAt: .now, batchCompletedAt: .now)
            defer { fixture.removeFiles() }
            let service = BackupService(dbQueue: fixture.database.dbQueue, applicationSupportURL: fixture.testRootURL)
            let generation = try await service.createGeneration(vaultIds: [fixture.meeting.vaultId])
            let identifier = try #require(AppDatabaseManager.migrationIdentifiers.dropLast().last)
            let oldURL = fixture.testRootURL.appending(path: "older.sqlite")
            let old = try DatabaseQueue(path: oldURL.path, configuration: AppDatabaseManager.configuration())
            try AppDatabaseManager.migrator.migrate(old, upTo: identifier)
            try await old.writeWithoutTransaction { db in
                try db.execute(sql: "ATTACH DATABASE ? AS current_backup", arguments: [generation.fileURL.path])
            }
            try await old.write { db in
                try db.execute(sql: "INSERT INTO vaults SELECT * FROM current_backup.vaults")
                try fixture.meeting.insert(db)
                try fixture.session.insert(db)
                if format == 2 {
                    try db.execute(sql: """
                    CREATE TABLE dahlia_backup_metadata AS
                    SELECT formatVersion, generationId, createdAt, schemaVersion, migrationIdentifier, appVersion, appBuild, reason,
                        ? AS vaultId, ? AS vaultName FROM current_backup.dahlia_backup_metadata
                    """, arguments: [fixture.meeting.vaultId.uuidString, "Test"])
                } else {
                    try db.execute(sql: "CREATE TABLE dahlia_backup_metadata AS SELECT * FROM current_backup.dahlia_backup_metadata")
                }
                try db.execute(
                    sql: "UPDATE dahlia_backup_metadata SET formatVersion = ?, migrationIdentifier = ?, schemaVersion = ?",
                    arguments: [format, identifier, AppDatabaseManager.schemaVersion(from: identifier)]
                )
            }
            try old.close()
            let originalHash = try BackupService.sha256(of: oldURL)
            let imported = try await service.importGeneration(from: oldURL)
            #expect(imported.metadata?.formatVersion == format)
            #expect(imported.metadata?.vaults == [BackupVault(id: fixture.meeting.vaultId, name: "Test")])
            _ = try await service.prepareRestore(from: imported, requests: [VaultBackupRestoreRequest(
                sourceVaultId: fixture.meeting.vaultId,
                targetVaultId: mode == .overwrite ? fixture.meeting.vaultId : .v7(),
                mode: mode, name: "Restored"
            )])
            let databaseURL = fixture.testRootURL.appending(path: "live.sqlite")
            let live = try AppDatabaseManager(path: databaseURL.path)
            try fixture.database.dbQueue.backup(to: live.dbQueue)
            try live.close()
            let outcome = BackupRestoreStartupProcessor.applyPendingRestore(applicationSupportURL: fixture.testRootURL, databaseURL: databaseURL)
            guard case .restored = outcome else { Issue.record("Older backup restore failed: \(outcome)")
                return
            }
            let result = try AppDatabaseManager(path: databaseURL.path)
            defer { try? result.close() }
            try await result.dbQueue.read { db throws in
                #expect(try MeetingRecord.fetchCount(db) == (mode == .overwrite ? 1 : 2))
                #expect(try AppDatabaseManager.hasExpectedCurrentSchema(db))
            }
            #expect(try BackupService.sha256(of: oldURL) == originalHash)
            #expect(try BackupService.sha256(of: imported.fileURL) == originalHash)
        }

        private func verifyExport(_ generation: BackupGeneration, fixture: BatchAudioTestFixture) throws {
            let exported = try DatabaseQueue(path: generation.fileURL.path)
            defer { try? exported.close() }
            try exported.read { db throws in
                #expect(try VaultRecord.fetchCount(db) == 1)
                let vault = try #require(try VaultRecord.fetchOne(db, key: fixture.meeting.vaultId))
                #expect(vault.path == nil)
                #expect(vault.accountConnectionId == nil)
                #expect(vault.syncRole == nil)
                #expect(vault.syncConfirmedConnectionId == nil)
                #expect(vault.syncPullCursor == nil)
                for table in ["dahlia_account_connections", "sync_transactions", "sync_operations", "search_documents", "recording_audio_segments"] {
                    #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") == 0)
                }
            }
        }

        private func seedRelationships(_ fixture: BatchAudioTestFixture) throws {
            let vaultID = fixture.meeting.vaultId
            let parent = ProjectRecord(id: .v7(), vaultId: vaultID, path: "Parent", createdAt: fixture.now)
            let child = ProjectRecord(
                id: .v7(),
                vaultId: vaultID,
                parentProjectId: parent.id,
                name: "Child",
                createdAt: fixture.now,
                projectType: nil
            )
            let screenshot = MeetingScreenshotRecord(
                id: .v7(),
                meetingId: fixture.meeting.id,
                sessionId: fixture.session.id,
                capturedAt: fixture.now,
                imageData: Data([1, 2, 3]),
                mimeType: "image/png",
                ocrText: "saved",
                caption: "saved"
            )
            let document = SummaryDocument(
                title: "Summary",
                sections: [SummarySection(id: .v7(), heading: "Image", blocks: [.image(screenshotId: screenshot.id, caption: "Caption")])]
            )
            try fixture.database.dbQueue.write { db in
                try parent.insert(db)
                try child.insert(db)
                try db.execute(sql: "UPDATE meetings SET projectId = ? WHERE id = ?", arguments: [child.id, fixture.meeting.id])
                try screenshot.insert(db)
                try SummaryRecord(meetingId: fixture.meeting.id, title: "Summary", document: document.databaseJSONString(), createdAt: fixture.now)
                    .insert(db)
                try SummaryExportRecord(
                    meetingId: fixture.meeting.id,
                    type: .googleDocs,
                    url: "https://docs.google.com/document/d/test/edit",
                    createdAt: fixture.now,
                    updatedAt: fixture.now
                ).insert(db)
                try db.execute(sql: "INSERT INTO tags(name, colorHex, createdAt) VALUES ('Shared', '#000000', ?)", arguments: [fixture.now])
                try db.execute(sql: "INSERT INTO meeting_tags(meetingId, tagId) VALUES (?, ?)", arguments: [fixture.meeting.id, db.lastInsertedRowID])
                let organization = OrganizationRecord(
                    id: .v7(),
                    vaultId: vaultID,
                    parentOrganizationId: nil,
                    nodeKind: .organization,
                    name: "Company",
                    revision: 1,
                    createdAt: fixture.now,
                    updatedAt: fixture.now
                )
                let unit = OrganizationRecord(
                    id: .v7(),
                    vaultId: vaultID,
                    parentOrganizationId: organization.id,
                    nodeKind: .unit,
                    name: "Team",
                    revision: 1,
                    createdAt: fixture.now,
                    updatedAt: fixture.now
                )
                let contact = ContactRecord(
                    id: .v7(),
                    vaultId: vaultID,
                    email: "test@example.invalid",
                    displayName: "Person",
                    revision: 1,
                    createdAt: fixture.now,
                    updatedAt: fixture.now
                )
                try organization.insert(db)
                try unit.insert(db)
                try contact.insert(db)
                try OrganizationMembershipRecord(organizationId: unit.id, contactId: contact.id, roleLabel: nil, createdAt: fixture.now).insert(db)
                try OrganizationDomainRecord(
                    vaultId: vaultID,
                    domainName: "example.invalid",
                    organizationId: organization.id,
                    isPrimary: true,
                    firstObservedAt: fixture.now,
                    lastObservedAt: fixture.now
                ).insert(db)
                try OrganizationDomainRecord(
                    vaultId: vaultID,
                    domainName: "alpha.invalid",
                    organizationId: organization.id,
                    isPrimary: false,
                    firstObservedAt: fixture.now,
                    lastObservedAt: fixture.now
                ).insert(db)
                try ProjectResourceReferenceRecord(
                    id: .v7(),
                    projectId: child.id,
                    resourceType: .contact,
                    resourceId: contact.id,
                    relationLabel: "Contact",
                    createdAt: fixture.now,
                    updatedAt: fixture.now
                ).insert(db)
                let topicID = UUID.v7()
                try db.execute(
                    sql: "INSERT INTO conversation_topics(id, vaultId, title, currentState, createdAt, updatedAt) VALUES (?, ?, 'Topic', 'Current', ?, ?)",
                    arguments: [topicID, vaultID, fixture.now, fixture.now]
                )
                try db.execute(
                    sql: "INSERT INTO conversation_topic_references(topicId, resourceType, resourceId, note, createdAt, updatedAt) VALUES (?, 'meeting', ?, 'Evidence', ?, ?)",
                    arguments: [topicID, fixture.meeting.id, fixture.now, fixture.now]
                )
            }
        }
    }
#endif
