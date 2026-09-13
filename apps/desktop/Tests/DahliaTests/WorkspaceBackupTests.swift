import DahliaMeetingAccess
import DahliaRuntimeSupport
import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct WorkspaceBackupTests {
        @Test(arguments: [WorkspaceBackupRestoreRequest.Mode.overwrite, .newWorkspace])
        func restoresOnlySelectedWorkspace(mode: WorkspaceBackupRestoreRequest.Mode) async throws {
            let fixture = try BatchAudioTestFixture(name: "WorkspaceRestore", endedAt: .now, batchCompletedAt: .now)
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
            let other = WorkspaceRecord(id: .v7(), path: nil, name: "Other", createdAt: .now, lastOpenedAt: .now)
            let connection = DahliaAccountConnectionRecord(id: .v7(), origin: "https://example.invalid", clientID: "test", createdAt: .now)
            try await fixture.database.dbQueue.write { db in
                try connection.insert(db)
                var synced = other
                synced.accountConnectionId = connection.id
                synced.organizationId = synced.accountConnectionId == nil ? nil : (synced.organizationId ?? .v7())
                synced.syncRole = "admin"
                synced.syncPullCursor = "keep-cursor"
                try synced.insert(db)
                try db.execute(
                    sql: "INSERT INTO sync_transactions(id, workspace_id, connectionId, createdAt, availableAt) VALUES (?, ?, ?, ?, ?)",
                    arguments: [UUID.v7(), other.id, connection.id, Date(), Date()]
                )
            }
            let service = BackupService(dbQueue: fixture.database.dbQueue, applicationSupportURL: fixture.testRootURL)
            let generation = try await service.createGeneration(workspaceIds: [fixture.meeting.workspaceId])
            try verifyExport(generation, fixture: fixture)
            try await fixture.database.dbQueue.write { db in
                if mode == .newWorkspace {
                    try db.execute(
                        sql: """
                        UPDATE workspaces SET accountConnectionId = ?, organizationId = COALESCE(organizationId, id),
                        syncConfirmedConnectionId = ?, syncRole = 'viewer', syncPullCursor = 'member-cursor' WHERE id = ?
                        """,
                        arguments: [connection.id, connection.id, fixture.meeting.workspaceId]
                    )
                }
            }
            let databaseURL = fixture.testRootURL.appending(path: "live.sqlite")
            let live = try AppDatabaseManager(path: databaseURL.path, enablesConcurrentSearch: true)
            try fixture.database.dbQueue.backup(to: live.dbQueue)
            try await live.dbQueue.write { db in
                try db.execute(sql: "UPDATE meetings SET name = 'Changed' WHERE id = ?", arguments: [fixture.meeting.id])
                try db.execute(sql: "UPDATE workspaces SET name = 'Other changed after backup' WHERE id = ?", arguments: [other.id])
            }
            try live.close()
            let audioURL = fixture.testRootURL.appending(path: "BatchAudio/audio.caf")
            try FileManager.default.createDirectory(at: audioURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("keep audio".utf8).write(to: audioURL)
            let targetID = mode == .overwrite ? fixture.meeting.workspaceId : UUID.v7()
            let request = WorkspaceBackupRestoreRequest(
                sourceWorkspaceId: fixture.meeting.workspaceId,
                targetWorkspaceId: targetID,
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
                try db.execute(sql: "UPDATE workspaces SET name = 'Other changed after preparation' WHERE id = ?", arguments: [other.id])
            }
            try lateWriter.close()
            let outcome = BackupRestoreStartupProcessor.applyPendingRestore(applicationSupportURL: fixture.testRootURL, databaseURL: databaseURL)
            guard case let .completed(results) = outcome, results.allSatisfy({ $0.error == nil }) else { Issue.record("Restore failed: \(outcome)")
                return
            }
            let result = try AppDatabaseManager(path: databaseURL.path)
            defer { try? result.close() }
            try await result.dbQueue.read { db throws in
                #expect(try WorkspaceRecord.fetchCount(db) == (mode == .overwrite ? 2 : 3))
                #expect(try WorkspaceRecord.fetchOne(db, key: other.id)?.name == "Other changed after preparation")
                #expect(try WorkspaceRecord.fetchOne(db, key: other.id)?.syncPullCursor == "keep-cursor")
                #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_transactions") == 1)
                let workspace = try #require(try WorkspaceRecord.fetchOne(db, key: targetID))
                #expect(workspace.accountConnectionId == nil)
                #expect(workspace.path == (mode == .overwrite ? fixture.workspaceURL.path : nil))
                let meeting = try #require(try MeetingRecord.filter(Column("workspace_id") == targetID).fetchOne(db))
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
                #expect(screenshot.ocrText == "saved")
                #expect(screenshot.caption == "saved")
                let analysisJobCount = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM jobs_search_index WHERE targetKind = 'screenshotAnalysis' AND targetKey = ?",
                    arguments: [screenshot.id]
                )
                try #require(analysisJobCount == 0)
                let summary = try #require(try SummaryContent.fetchOne(db, key: meeting.id))
                #expect(try summary.loadDocument().referencedScreenshotIds == [screenshot.id])
                #expect(try SummaryExportRecord.filter(Column("meetingId") == meeting.id).fetchCount(db) == (mode == .overwrite ? 1 : 0))
                #expect(screenshot.imageData == nil)
                let source = try #require(screenshot.localSource)
                let files = try ScreenshotFileStore(directory: fixture.testRootURL.appending(path: "FileStore"), readOnly: true)
                #expect(try files.read(source, variant: .original)?.data == Data([1, 2, 3]))
                let projects = try ProjectRecord.fetchResolvedAll(workspaceId: targetID, in: db)
                #expect(Set(projects.map(\.path)) == ["Parent", "Parent/Child"])
                let calendarEvent = try #require(try CalendarEventRecord.fetchOne(
                    db,
                    key: ["ical_uid": "backup@example.invalid", "recurrence_id": ""]
                ))
                #expect(calendarEvent.attendees == [
                    CalendarAttendeeSnapshot(email: "person@example.invalid", displayName: "Person"),
                ])
                try WorkspaceBackupTransfer.validateIntegrity(in: db)
            }
            #expect(try Data(contentsOf: audioURL) == Data("keep audio".utf8))
            let generations = try await service.listGenerations()
            #expect(generations.filter { $0.metadata?.reason == .beforeRestore }.count == (mode == .overwrite ? 1 : 0))
            await result.searchIndexer.drain()
            let indexedCount = try await result.dbQueue.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM search_documents WHERE workspace_id = ?", arguments: [targetID]) ?? 0
            }
            #expect(indexedCount > 0)
        }

        @Test
        func repeatedNewRestoreUsesDistinctIDsAndPreservesSharedTags() async throws {
            let fixture = try BatchAudioTestFixture(name: "RepeatedRestore", endedAt: .now, batchCompletedAt: .now)
            defer { fixture.removeFiles() }
            try seedRelationships(fixture)
            let service = BackupService(dbQueue: fixture.database.dbQueue, applicationSupportURL: fixture.testRootURL)
            let generation = try await service.createGeneration(workspaceIds: [fixture.meeting.workspaceId])
            let databaseURL = fixture.testRootURL.appending(path: "live.sqlite")
            let live = try AppDatabaseManager(path: databaseURL.path, enablesConcurrentSearch: true)
            try fixture.database.dbQueue.backup(to: live.dbQueue)
            try await live.dbQueue.write { try $0.execute(sql: "UPDATE tags SET colorHex = '#ffffff'") }
            try live.close()
            for _ in 0 ..< 2 {
                _ = try await service.prepareRestore(from: generation, requests: [WorkspaceBackupRestoreRequest(
                    sourceWorkspaceId: fixture.meeting.workspaceId, targetWorkspaceId: .v7(), mode: .newWorkspace, name: "Same name"
                )])
                let outcome = BackupRestoreStartupProcessor.applyPendingRestore(applicationSupportURL: fixture.testRootURL, databaseURL: databaseURL)
                guard case let .completed(results) = outcome,
                      results.allSatisfy({ $0.error == nil }) else { Issue.record("Restore failed: \(outcome)")
                    return
                }
            }
            let result = try AppDatabaseManager(path: databaseURL.path)
            defer { try? result.close() }
            try await result.dbQueue.read { db throws in
                #expect(try WorkspaceRecord.fetchCount(db) == 3)
                #expect(try MeetingRecord.fetchCount(db) == 3)
                #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tags") == 1)
                #expect(try String.fetchOne(db, sql: "SELECT colorHex FROM tags") == "#ffffff")
                #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM meeting_tags") == 3)
                try WorkspaceBackupTransfer.validateIntegrity(in: db)
            }
        }

        @Test
        func rejectsSyncedOrMissingOverwriteTarget() async throws {
            let fixture = try BatchAudioTestFixture(name: "RestoreTarget")
            defer { fixture.removeFiles() }
            let service = BackupService(dbQueue: fixture.database.dbQueue, applicationSupportURL: fixture.testRootURL)
            let generation = try await service.createGeneration(workspaceIds: [fixture.meeting.workspaceId])
            let request = WorkspaceBackupRestoreRequest(
                sourceWorkspaceId: fixture.meeting.workspaceId,
                targetWorkspaceId: fixture.meeting.workspaceId,
                mode: .overwrite,
                name: "Test"
            )
            try await fixture.database.dbQueue.write { db in
                try db.execute(sql: "UPDATE workspaces SET syncRole = 'admin'")
            }
            await #expect(throws: BackupServiceError.restoreTargetUnavailable) { try await service.prepareRestore(
                from: generation,
                requests: [request]
            )
            }
            _ = try await fixture.database.dbQueue.write { try WorkspaceRecord.deleteAll($0) }
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
            let generation = try await service.createGeneration(workspaceIds: [fixture.meeting.workspaceId])
            _ = try await service.prepareRestore(from: generation, requests: [WorkspaceBackupRestoreRequest(
                sourceWorkspaceId: fixture.meeting.workspaceId, targetWorkspaceId: fixture.meeting.workspaceId, mode: .overwrite, name: "Test"
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
            guard case let .completed(results) = outcome, results.count == 1, results[0].error != nil else { Issue.record("Expected safety failure")
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
            #expect(unavailable.workspaces.isEmpty)
            #expect(unavailable.selectedWorkspaceIds.isEmpty)
            let model = BackupSettingsViewModel(dbQueue: fixture.database.dbQueue, applicationSupportURL: fixture.testRootURL)
            model.selectedWorkspaceIds = [fixture.meeting.workspaceId]
            await model.refresh()
            #expect(model.generations.isEmpty)
            #expect(model.selectedWorkspaceIds == [fixture.meeting.workspaceId])
            await model.createBackup()
            let metadata = try #require(model.generations.first?.metadata)
            #expect(model.canOverwrite(workspaceId: metadata.workspaces[0].id))
            #expect(!model.isBusy)
            try await fixture.database.dbQueue.write { try $0.execute(sql: "UPDATE workspaces SET syncRole = 'admin'") }
            await model.refresh()
            #expect(!model.canOverwrite(workspaceId: metadata.workspaces[0].id))
            await model.importBackup(from: fixture.testRootURL.appending(path: "missing.sqlite"))
            #expect(model.errorMessage != nil)
            #expect(!model.isBusy)
        }

        @Test
        func corruptHierarchyCannotSilentlyOmitProjects() async throws {
            let fixture = try BatchAudioTestFixture(name: "CorruptHierarchy")
            defer { fixture.removeFiles() }
            let parent = ProjectRecord(id: .v7(), workspaceId: fixture.meeting.workspaceId, path: "Parent", createdAt: .now)
            let child = ProjectRecord(
                id: .v7(),
                workspaceId: fixture.meeting.workspaceId,
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
            let generation = try await service.createGeneration(workspaceIds: [fixture.meeting.workspaceId])
            try editBackupDatabase(generation.fileURL) { db in
                let trigger = try String.fetchOne(db, sql: "SELECT sql FROM sqlite_master WHERE name = 'projects_validate_parent_update'")!
                try db.execute(sql: "DROP TRIGGER projects_validate_parent_update")
                try db.execute(sql: "UPDATE projects SET parentProjectId = ? WHERE id = ?", arguments: [UUID.v7(), child.id])
                try db.execute(sql: trigger)
            }

            _ = try await service.prepareRestore(from: generation, requests: [WorkspaceBackupRestoreRequest(
                sourceWorkspaceId: fixture.meeting.workspaceId, targetWorkspaceId: .v7(), mode: .newWorkspace, name: "New"
            )])
            let databaseURL = fixture.testRootURL.appending(path: "live.sqlite")
            let live = try AppDatabaseManager(path: databaseURL.path)
            try fixture.database.dbQueue.backup(to: live.dbQueue)
            try live.close()
            let outcome = BackupRestoreStartupProcessor.applyPendingRestore(applicationSupportURL: fixture.testRootURL, databaseURL: databaseURL)
            guard case let .completed(results) = outcome, results.count == 1,
                  results[0].error != nil else { Issue.record("Invalid hierarchy must fail, not omit rows")
                return
            }
            let result = try AppDatabaseManager(path: databaseURL.path)
            defer { try? result.close() }
            let counts = try await result.dbQueue.read { db in try (WorkspaceRecord.fetchCount(db), ProjectRecord.fetchCount(db)) }
            #expect(counts.0 == 1)
            #expect(counts.1 == 2)
        }

        private func verifyExport(_ generation: BackupGeneration, fixture: BatchAudioTestFixture) throws {
            let exported = try DatabaseQueue(path: extractedBackupDatabase(generation.fileURL).path)
            defer { try? exported.close() }
            try exported.read { db throws in
                #expect(try WorkspaceRecord.fetchCount(db) == 1)
                let workspace = try #require(try WorkspaceRecord.fetchOne(db, key: fixture.meeting.workspaceId))
                #expect(workspace.path == nil)
                #expect(workspace.accountConnectionId == nil)
                #expect(workspace.syncRole == nil)
                #expect(workspace.syncConfirmedConnectionId == nil)
                #expect(workspace.syncPullCursor == nil)
                for table in ["dahlia_account_connections", "sync_transactions", "sync_operations", "search_documents", "recording_audio_segments"] {
                    #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") == 0)
                }
            }
        }

        private func seedRelationships(_ fixture: BatchAudioTestFixture) throws {
            let parent = ProjectRecord(id: .v7(), workspaceId: fixture.meeting.workspaceId, path: "Parent", createdAt: fixture.now)
            let child = ProjectRecord(
                id: .v7(),
                workspaceId: fixture.meeting.workspaceId,
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
                try screenshot.insertLegacyForTesting(db)
                try SummaryContent(meetingId: fixture.meeting.id, title: "Summary", document: document.databaseJSONString(), createdAt: fixture.now)
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
                try db.execute(
                    sql: """
                    INSERT INTO calendar_events (
                        ical_uid, recurrence_id, created_at, updated_at, title, description,
                        start, end, is_all_day, attendees_json
                    ) VALUES (?, '', ?, ?, 'Backup event', '', ?, ?, 0, ?)
                    """,
                    arguments: [
                        "backup@example.invalid", fixture.now, fixture.now, fixture.now,
                        fixture.now.addingTimeInterval(3600),
                        #"[{"email":"person@example.invalid","display_name":"Person"}]"#,
                    ]
                )
                try db.execute(
                    sql: """
                    UPDATE meetings
                    SET calendar_event_ical_uid = 'backup@example.invalid', calendar_event_recurrence_id = ''
                    WHERE id = ?
                    """,
                    arguments: [fixture.meeting.id]
                )
            }
        }
    }
#endif
