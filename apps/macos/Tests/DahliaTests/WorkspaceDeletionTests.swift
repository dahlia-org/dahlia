#if canImport(Testing)
    import DahliaRuntimeSupport
    import Foundation
    import GRDB
    import Testing
    @testable import Dahlia

    @MainActor
    struct WorkspaceDeletionTests {
        @Test(arguments: [false, true], [false, true])
        func transferPreservesContentAndDisambiguatesNames(databricks: Bool, exportFolderExists: Bool) async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let account = DahliaAccountConnectionRecord(id: .v7(), origin: "https://gateway.example", clientID: "test", createdAt: .now)
            let source = WorkspaceRecord(
                id: .v7(),
                path: exportFolderExists ? FileManager.default.temporaryDirectory.path
                    : FileManager.default.temporaryDirectory.appending(path: UUID.v7().uuidString).path,
                name: "Source",
                createdAt: .now,
                lastOpenedAt: .now,
                databricksConnectionId: databricks ? account.id : nil
            )
            let destination = WorkspaceRecord(
                id: .v7(),
                path: nil,
                name: "Destination",
                createdAt: .now,
                lastOpenedAt: .now,
                databricksConnectionId: databricks ? account.id : nil
            )
            let root = ProjectRecord(
                id: .v7(),
                workspaceId: source.id,
                parentProjectId: nil,
                name: "Project",
                createdAt: .now,
                projectType: .undefined
            )
            let child = ProjectRecord(id: .v7(), workspaceId: source.id, parentProjectId: root.id, name: "Child", createdAt: .now, projectType: nil)
            let meeting = MeetingRecord(id: .v7(), workspaceId: source.id, projectId: child.id, name: "Meeting", createdAt: .now, updatedAt: .now)
            let sessionID = UUID.v7()
            let fileID = UUID.v7()
            let segmentID = UUID.v7()
            let contentIDs = try await database.dbQueue.write { db in
                try account.insert(db)
                try source.insert(db)
                try destination.insert(db)
                try root.insert(db)
                try child.insert(db)
                try ProjectRecord(
                    id: .v7(),
                    workspaceId: source.id,
                    parentProjectId: nil,
                    name: "Project (2)",
                    createdAt: .now,
                    projectType: .undefined
                ).insert(db)
                try ProjectRecord(
                    id: .v7(),
                    workspaceId: destination.id,
                    parentProjectId: nil,
                    name: "project",
                    createdAt: .now,
                    projectType: .undefined
                ).insert(db)
                try meeting.insert(db)
                try TranscriptSegmentRecord(id: segmentID, meetingId: meeting.id, startTime: .now, translatedText: "Translation").insert(db)
                try db.execute(sql: "INSERT INTO transcript_segment_bodies(segmentId, text) VALUES (?, 'Transcript')", arguments: [segmentID])
                try SummaryRecord(meetingId: meeting.id, title: "Summary", createdAt: .now).insert(db)
                try db.execute(sql: "INSERT INTO summary_bodies(meetingId, document) VALUES (?, 'Summary body')", arguments: [meeting.id])
                try RecordingSessionRecord(
                    id: sessionID,
                    meetingId: meeting.id,
                    startedAt: .now,
                    endedAt: .now,
                    duration: 1,
                    offsetSeconds: 0,
                    createdAt: .now,
                    updatedAt: .now
                ).insert(db)
                try db.execute(sql: """
                INSERT INTO recording_audio_files(id, recordingSessionId, source, relativePath, storageLocation, sampleRate, channelCount, createdAt, updatedAt)
                VALUES (?, ?, 'mic', 'audio.caf', 'vault', 16000, 1, ?, ?)
                """, arguments: [UUID.v7(), sessionID, Date.now, Date.now])
                try FileRecord(
                    id: fileID,
                    workspaceId: source.id,
                    size: 42,
                    contentType: "image/png",
                    checksum: "SHA-256:" + String(repeating: "a", count: 64),
                    name: "screenshot.png",
                    metadata: .init(source: .screenshot),
                    createdAt: .now,
                    updatedAt: .now,
                    localReference: "original-image.png"
                ).insert(db)
                try MeetingAttachmentRecord(id: .v7(), meetingId: meeting.id, fileId: fileID, createdAt: .now).insert(db)
                return try Self.insertDocumentsAndInstructions(sourceID: source.id, destinationID: destination.id, meetingID: meeting.id, in: db)
            }
            let model = WorkspaceManagementModel()
            await model.configure(appDatabase: database)
            #expect(model.deletionTransferCandidates(for: source).map(\.id) == [destination.id])
            #expect(await model.removeWorkspace(source, currentWorkspaceId: destination.id, transferringTo: destination.id))
            #expect(model.workspaces.map(\.id) == [destination.id])
            try await database.dbQueue.read { (db: Database) throws in
                #expect(try WorkspaceRecord.fetchOne(db, key: source.id) == nil)
                #expect(try MeetingRecord.fetchOne(db, key: meeting.id)?.projectId == child.id)
                #expect(try MeetingRecord.fetchOne(db, key: meeting.id)?.workspaceId == destination.id)
                #expect(try ProjectRecord.fetchOne(db, key: root.id)?.name == "Project (3)")
                #expect(try ProjectRecord.fetchOne(db, key: child.id)?.parentProjectId == root.id)
                #expect(try ProjectRecord.fetchCount(db) == 4)
                #expect(try DocumentRecord.fetchOne(db, key: contentIDs.notes)?.text == "Meeting notes")
                #expect(try DocumentRecord.fetchOne(db, key: contentIDs.document)?.workspaceId == destination.id)
                #expect(try DocumentPrivateCopyRecord.fetchOne(db)?.text == "Private notes")
                #expect(try DocumentPrivateCopyRecord.fetchOne(db)?.workspaceId == destination.id)
                #expect(try DocumentLocalArchiveRecord.fetchOne(db)?.payload == "retained")
                #expect(try DocumentLocalArchiveRecord.fetchOne(db)?.workspaceId == destination.id)
                #expect(try FileRecord.fetchOne(db, key: fileID)?.localReference == "original-image.png")
                #expect(try FileRecord.fetchOne(db, key: fileID)?.workspaceId == destination.id)
                #expect(try MeetingAttachmentRecord.fetchCount(db) == 1)
                #expect(try TranscriptSegmentRecord.fetchOne(db, key: segmentID)?.translatedText == "Translation")
                #expect(try String
                    .fetchOne(db, sql: "SELECT text FROM transcript_segment_bodies WHERE segmentId = ?", arguments: [segmentID]) == "Transcript")
                #expect(try String
                    .fetchOne(db, sql: "SELECT document FROM summary_bodies WHERE meetingId = ?", arguments: [meeting.id]) == "Summary body")
                #expect(try RecordingSessionRecord.fetchOne(db, key: sessionID)?.meetingId == meeting.id)
                #expect(try String.fetchOne(db, sql: "SELECT original_workspace_path FROM recording_audio_files") == source.path)
                #expect(try String.fetchOne(db, sql: "SELECT relativePath FROM recording_audio_files") == "audio.caf")
                #expect(try InstructionRecord.fetchOne(db, key: contentIDs.instruction)?.name == "Instructions (2)")
                #expect(try InstructionRecord.fetchCount(db) == 2)
                #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
            }
        }

        @Test(arguments: [false, true])
        func transferClearsOnlySourceRelativeExportsAtomically(rollsBack: Bool) async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let queue = database.dbQueue
            let repository = MeetingRepository(dbQueue: queue)
            try await Task.detached {
                let folder = FileManager.default.temporaryDirectory.appending(path: UUID.v7().uuidString)
                defer { try? FileManager.default.removeItem(at: folder) }
                let sourceURL = folder.appending(path: "source")
                let destinationURL = folder.appending(path: "destination")
                for directory in [sourceURL, destinationURL] {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try Data(directory.lastPathComponent.utf8).write(to: directory.appending(path: "review.md"))
                }
                let source = WorkspaceRecord(id: .v7(), path: sourceURL.path, name: "Source", createdAt: .now, lastOpenedAt: .now)
                let destination = WorkspaceRecord(id: .v7(), path: destinationURL.path, name: "Destination", createdAt: .now, lastOpenedAt: .now)
                let first = MeetingRecord(id: .v7(), workspaceId: source.id, name: "First", createdAt: .now, updatedAt: .now)
                let second = MeetingRecord(id: .v7(), workspaceId: source.id, name: "Second", createdAt: .now, updatedAt: .now)
                let existing = MeetingRecord(id: .v7(), workspaceId: destination.id, name: "Existing", createdAt: .now, updatedAt: .now)
                let document = SummaryDocument(
                    title: "New summary",
                    sections: [SummarySection(id: .v7(), heading: "Summary", blocks: [.paragraph("Body")])]
                )
                let googleURL = "https://docs.google.com/document/d/retained/edit"
                try await queue.write { db in
                    try source.insert(db)
                    try destination.insert(db)
                    for meeting in [first, second, existing] {
                        try meeting.insert(db)
                        try SummaryRecord(meetingId: meeting.id, title: "Summary", createdAt: .now).insert(db)
                        try db.execute(
                            sql: "INSERT INTO summary_bodies(meetingId, document) VALUES (?, ?)",
                            arguments: [meeting.id, document.databaseJSONString()]
                        )
                        try SummaryExportRecord.setURL(
                            SummaryExportRecord.workspaceURL(relativePath: "review.md"),
                            meetingId: meeting.id,
                            type: .workspace,
                            in: db
                        )
                    }
                    try SummaryExportRecord.setURL(googleURL, meetingId: first.id, type: .googleDocs, in: db)
                    if rollsBack {
                        try db
                            .execute(
                                sql: "CREATE TEMP TRIGGER fail_workspace_delete BEFORE DELETE ON workspaces BEGIN SELECT RAISE(ABORT, 'test failure'); END"
                            )
                    }
                }
                do {
                    try await repository.transferAndDeleteWorkspace(id: source.id, destinationID: destination.id)
                    #expect(!rollsBack)
                } catch {
                    #expect(rollsBack)
                }
                let relativePath = try await queue.read { (db: Database) throws -> String? in
                    for meeting in [first, second] {
                        let record = try SummaryExportRecord.fetchOne(meetingId: meeting.id, type: .workspace, in: db)
                        #expect((record != nil) == rollsBack)
                        #expect(try MeetingRecord.fetchOne(db, key: meeting.id)?.workspaceId == (rollsBack ? source.id : destination.id))
                    }
                    #expect(try SummaryExportRecord.fetchOne(meetingId: first.id, type: .googleDocs, in: db)?.url == googleURL)
                    #expect(try SummaryExportRecord.fetchOne(meetingId: existing.id, type: .workspace, in: db)?.workspaceRelativePath == "review.md")
                    return try SummaryExportRecord.fetchOne(meetingId: first.id, type: .workspace, in: db)?.workspaceRelativePath
                }
                if !rollsBack {
                    #expect(throws: ProjectWorkspaceError.invalidMoveDestination) {
                        try repository.updateSummaryWorkspaceRelativePath(
                            forMeetingId: first.id, relativePath: "review.md", expectedWorkspaceID: source.id
                        )
                    }
                    let staleRequest = WorkspaceSummaryExportService.LockedSummaryExportRequest(
                        workspaceURL: sourceURL, workspaceID: source.id, meetingID: first.id, dbQueue: queue,
                        document: document, summaryFileName: "review.md", summaryMarkdown: "New summary",
                        previousWorkspaceRelativePath: "review.md", previousWorkspaceID: source.id
                    )
                    #expect(try await WorkspaceSummaryExportService.exportSummary(staleRequest) == nil)
                    let currentRequest = WorkspaceSummaryExportService.LockedSummaryExportRequest(
                        workspaceURL: destinationURL, workspaceID: destination.id, meetingID: first.id, dbQueue: queue,
                        document: document, summaryFileName: "review.md", summaryMarkdown: "New summary",
                        previousWorkspaceRelativePath: "review.md", previousWorkspaceID: source.id
                    )
                    let result = try #require(try await WorkspaceSummaryExportService.exportSummary(currentRequest))
                    #expect(result.fileURL.lastPathComponent == "review-\(first.id.uuidString).md")
                    #expect(relativePath == nil)
                    var repeatRequest = currentRequest
                    repeatRequest.previousWorkspaceRelativePath = result.fileURL.lastPathComponent
                    repeatRequest.previousWorkspaceID = destination.id
                    let repeated = try #require(try await WorkspaceSummaryExportService.exportSummary(repeatRequest))
                    #expect(repeated.fileURL == result.fileURL)
                }
                #expect(try String(contentsOf: sourceURL.appending(path: "review.md"), encoding: .utf8) == "source")
                #expect(try String(contentsOf: destinationURL.appending(path: "review.md"), encoding: .utf8) == "destination")
            }.value
        }

        @Test
        func transferRejectsActiveExportAndSucceedsAfterItFinishes() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let queue = database.dbQueue
            let repository = MeetingRepository(dbQueue: queue)
            try await Task.detached {
                let folder = FileManager.default.temporaryDirectory.appending(path: UUID.v7().uuidString)
                defer { try? FileManager.default.removeItem(at: folder) }
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let source = WorkspaceRecord(id: .v7(), path: folder.path, name: "Source", createdAt: .now, lastOpenedAt: .now)
                let destination = WorkspaceRecord(id: .v7(), path: nil, name: "Destination", createdAt: .now, lastOpenedAt: .now)
                let meeting = MeetingRecord(id: .v7(), workspaceId: source.id, name: "Meeting", createdAt: .now, updatedAt: .now)
                try await queue.write { db in
                    try source.insert(db)
                    try destination.insert(db)
                    try meeting.insert(db)
                }
                let held = AsyncStream<Void>.makeStream()
                let release = DispatchSemaphore(value: 0)
                let exporter = Task.detached {
                    defer { held.continuation.finish() }
                    try DahliaWorkspaceMutationLock.withLock(workspaceURL: folder, workspaceID: source.id) {
                        held.continuation.yield(())
                        #expect(release.wait(timeout: .now() + 10) == .success)
                    }
                }
                var events = held.stream.makeAsyncIterator()
                _ = await events.next()
                do {
                    try await repository.transferAndDeleteWorkspace(id: source.id, destinationID: destination.id)
                    Issue.record("Transfer must not race an active export")
                } catch {
                    #expect(error as? ProjectWorkspaceError == .workspaceBusy)
                }
                release.signal()
                try await exporter.value
                try await queue.read { (db: Database) throws in
                    #expect(try MeetingRecord.fetchOne(db, key: meeting.id)?.workspaceId == source.id)
                    #expect(try WorkspaceRecord.fetchOne(db, key: source.id) != nil)
                }
                try await repository.transferAndDeleteWorkspace(id: source.id, destinationID: destination.id)
                try await queue.read { (db: Database) throws in
                    #expect(try MeetingRecord.fetchOne(db, key: meeting.id)?.workspaceId == destination.id)
                    #expect(try WorkspaceRecord.fetchOne(db, key: source.id) == nil)
                }
            }.value
        }

        private nonisolated static func insertDocumentsAndInstructions(
            sourceID: UUID, destinationID: UUID, meetingID: UUID, in db: Database
        ) throws -> (notes: UUID, document: UUID, instruction: UUID) {
            let notesID = UUID.v7()
            let documentID = UUID.v7()
            let instructionID = UUID.v7()
            try DocumentRecord(
                id: notesID,
                workspaceId: sourceID,
                meetingId: meetingID,
                checkpoint: "AAA=",
                text: "Meeting notes",
                createdAt: .now,
                updatedAt: .now
            ).insert(db)
            try DocumentRecord(
                id: documentID,
                workspaceId: sourceID,
                kind: "general",
                checkpoint: "AAA=",
                text: "Document",
                createdAt: .now,
                updatedAt: .now
            ).insert(db)
            try DocumentPrivateCopyRecord(
                id: .v7(),
                workspaceId: sourceID,
                meetingId: meetingID,
                checkpoint: "AAA=",
                text: "Private notes",
                createdAt: .now,
                updatedAt: .now
            ).insert(db)
            try DocumentLocalArchiveRecord(
                id: .v7(),
                workspaceId: sourceID,
                meetingId: nil,
                name: "Archive",
                payload: "retained",
                createdAt: .now
            ).insert(db)
            try InstructionRecord(
                id: instructionID,
                workspaceId: sourceID,
                name: "Instructions",
                content: "Original",
                createdAt: .now,
                updatedAt: .now
            ).insert(db)
            try InstructionRecord(
                id: .v7(),
                workspaceId: destinationID,
                name: "Instructions",
                content: "Existing",
                createdAt: .now,
                updatedAt: .now
            ).insert(db)
            return (notesID, documentID, instructionID)
        }

        @Test(arguments: ["same", "missing", "otherAccount", "server", "recording", "destinationRecording", "fence", "rollback"])
        func invalidTransferPreservesSource(reason: String) async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let account = DahliaAccountConnectionRecord(id: .v7(), origin: "https://example.com", clientID: "test", createdAt: .now)
            let source = WorkspaceRecord(id: .v7(), path: nil, name: "Source", createdAt: .now, lastOpenedAt: .now)
            var destination = WorkspaceRecord(id: .v7(), path: nil, name: "Destination", createdAt: .now, lastOpenedAt: .now)
            if reason == "otherAccount" { destination.databricksConnectionId = account.id }
            if reason == "server" {
                destination.accountConnectionId = account.id
                destination.organizationId = .v7()
                destination.syncRole = "admin"
            }
            let target = destination
            let meeting = MeetingRecord(
                id: .v7(),
                workspaceId: reason == "destinationRecording" ? target.id : source.id,
                name: "Retained",
                createdAt: .now,
                updatedAt: .now
            )
            try await database.dbQueue.write { db in
                try account.insert(db)
                try source.insert(db)
                if reason != "missing" { try target.insert(db) }
                try meeting.insert(db)
                if reason == "recording" || reason == "destinationRecording" {
                    try RecordingSessionRecord(
                        id: .v7(),
                        meetingId: meeting.id,
                        startedAt: .now,
                        offsetSeconds: 0,
                        createdAt: .now,
                        updatedAt: .now
                    ).insert(db)
                }
                if reason == "fence" { _ = try WorkspaceTransferFence.create(workspaceIDs: [source.id], in: db) }
                if reason == "rollback" {
                    try db
                        .execute(
                            sql: "CREATE TEMP TRIGGER fail_workspace_delete BEFORE DELETE ON workspaces BEGIN SELECT RAISE(ABORT, 'test failure'); END"
                        )
                }
            }
            let model = WorkspaceManagementModel()
            await model.configure(appDatabase: database)
            #expect(await !model.removeWorkspace(source, currentWorkspaceId: nil, transferringTo: reason == "same" ? source.id : target.id))
            try await database.dbQueue.read { (db: Database) throws in
                #expect(try WorkspaceRecord.fetchOne(db, key: source.id) != nil)
                #expect(try MeetingRecord.fetchOne(db, key: meeting.id)?.workspaceId == (reason == "destinationRecording" ? target.id : source.id))
                #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
            }
        }
    }
#endif
