#if canImport(Testing)
    import Foundation
    import GRDB
    import Testing
    @testable import Dahlia

    @MainActor
    struct WorkspaceRelocationTests {
        @Test(arguments: [false, true])
        func preservesRecordingAndIDsWithEitherWorkspaceLoadedFirst(destinationExists: Bool) throws {
            let queue = try DatabaseQueue()
            try AppDatabaseManager.migrator.migrate(queue)
            let connection = DahliaAccountConnectionRecord(id: .v7(), origin: "https://example.com", clientID: "test", createdAt: .now)
            let source = WorkspaceRecord(
                id: .v7(),
                path: "/tmp/source",
                name: "Source",
                createdAt: .now,
                lastOpenedAt: .now,
                accountConnectionId: connection.id,
                organizationId: .v7(), syncRole: "admin",
                syncConfirmedConnectionId: connection.id
            )
            let destination = WorkspaceRecord(
                id: .v7(),
                path: nil,
                name: "Destination",
                createdAt: .now,
                lastOpenedAt: .now,
                accountConnectionId: connection.id,
                organizationId: .v7(), syncRole: "admin",
                syncConfirmedConnectionId: connection.id
            )
            let root = ProjectRecord(id: .v7(), workspaceId: source.id, parentProjectId: nil, name: "Root", createdAt: .now, projectType: .undefined)
            let child = ProjectRecord(id: .v7(), workspaceId: source.id, parentProjectId: root.id, name: "Child", createdAt: .now, projectType: nil)
            let meeting = MeetingRecord(id: .v7(), workspaceId: source.id, projectId: child.id, name: "Recorded", createdAt: .now, updatedAt: .now)
            let session = RecordingSessionRecord(
                id: .v7(),
                meetingId: meeting.id,
                startedAt: .now,
                endedAt: .now,
                duration: 1,
                offsetSeconds: 0,
                createdAt: .now,
                updatedAt: .now
            )
            try queue.write { db in
                try connection.insert(db)
                try source.insert(db)
                if destinationExists { try destination.insert(db) }
                try root.insert(db)
                try child.insert(db)
                try meeting.insert(db)
                try db.execute(sql: """
                INSERT INTO recording_sessions(id, meetingId, startedAt, endedAt, duration, offsetSeconds, createdAt, updatedAt, transcriptionMode)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    session.id, session.meetingId, session.startedAt, session.endedAt, session.duration,
                    session.offsetSeconds, session.createdAt, session.updatedAt, session.transcriptionMode.rawValue,
                ])
                try db.execute(sql: """
                INSERT INTO recording_audio_files(id, recordingSessionId, source, relativePath, storageLocation, sampleRate, channelCount, createdAt, updatedAt)
                VALUES (?, ?, 'mic', 'audio.caf', 'vault', 16000, 1, ?, ?)
                """, arguments: [UUID.v7(), session.id, Date.now, Date.now])
            }
            try AppDatabaseManager.migrator.migrate(queue)
            let relocation = WorkspaceRelocation(
                workspaces: [.init(
                    workspaceId: destination.id,
                    organizationId: destination.organizationId ?? .v7(),
                    name: destination.name,
                    createdAt: .now,
                    role: "admin"
                )],
                items: [
                    .init(entity: .meeting, id: meeting.id, workspaceId: destination.id),
                    .init(entity: .project, id: child.id, workspaceId: destination.id),
                    .init(entity: .project, id: root.id, workspaceId: destination.id),
                ]
            )
            #expect(try queue.write { try relocation.apply(connectionId: connection.id, in: $0) })
            #expect(try !queue.write { try relocation.apply(connectionId: connection.id, in: $0) })
            try queue.read { (db: Database) throws in
                #expect(try MeetingRecord.fetchOne(db, key: meeting.id)?.workspaceId == destination.id)
                #expect(try ProjectRecord.fetchOne(db, key: child.id)?.parentProjectId == root.id)
                #expect(try RecordingSessionRecord.fetchOne(db, key: session.id)?.meetingId == meeting.id)
                #expect(try String.fetchOne(db, sql: "SELECT original_workspace_path FROM recording_audio_files") == "/tmp/source")
                #expect(try String.fetchOne(db, sql: "SELECT relativePath FROM recording_audio_files") == "audio.caf")
                #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
            }
        }

        @Test(arguments: ["transaction", "pending", "failed", "syncing", "saved", "remote", "acknowledged", "partial"])
        func pendingChangesStopRelocationWithoutDiscardingData(state: String) throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let connection = DahliaAccountConnectionRecord(id: .v7(), origin: "https://example.com", clientID: "test", createdAt: .now)
            let source = WorkspaceRecord(
                id: .v7(),
                path: nil,
                name: "Source",
                createdAt: .now,
                lastOpenedAt: .now,
                accountConnectionId: connection.id,
                organizationId: .v7(), syncRole: "admin",
                syncConfirmedConnectionId: connection.id
            )
            let meeting = MeetingRecord(id: .v7(), workspaceId: source.id, projectId: nil, name: "Local", createdAt: .now, updatedAt: .now)
            let target = UUID.v7()
            try database.dbQueue.write { db in
                try connection.insert(db)
                try source.insert(db)
                try meeting.insert(db)
                if state == "transaction" {
                    try SyncTransactionRecorder.record(
                        workspaceId: source.id,
                        operations: [SyncInitialSnapshotBuilder.workspaceOperation(source, action: .update)],
                        in: db
                    )
                } else {
                    let session = RecordingSessionRecord(
                        id: .v7(), meetingId: meeting.id, startedAt: .now, endedAt: .now,
                        duration: 1, offsetSeconds: 0, createdAt: .now, updatedAt: .now
                    )
                    try session.insert(db)
                    var archive = RecordingArchiveRecord(
                        sessionId: session.id, meetingId: meeting.id, workspaceId: source.id,
                        connectionId: connection.id, state: ["acknowledged", "partial"].contains(state) ? "syncing" : state
                    )
                    if state == "acknowledged" || state == "partial" {
                        archive.number = 1
                        let manifest = RecordingArchiveManifest(sampleRate: 16000, frameCount: 1, ranges: [])
                        let prepared = RecordingArchiveEncoder.Prepared(relativePath: "audio.m4a", size: 1, checksum: "checksum", manifest: manifest)
                        let audio = RecordingArchivedAudio(
                            contentType: "audio/mp4",
                            size: 1,
                            checksum: "checksum",
                            contentURL: "/audio",
                            manifest: manifest
                        )
                        archive.preparedJSON = try String(decoding: SyncJSON.encoder.encode(["mic": prepared, "system": prepared]), as: UTF8.self)
                        archive.audioJSON = try String(
                            decoding: SyncJSON.encoder.encode(state == "partial" ? ["mic": audio] : ["mic": audio, "system": audio]),
                            as: UTF8.self
                        )
                    }
                    try archive.insert(db)
                }
            }
            let relocation = WorkspaceRelocation(
                workspaces: [.init(workspaceId: target, organizationId: .v7(), name: "Destination", createdAt: .now, role: "admin")],
                items: [.init(entity: .meeting, id: meeting.id, workspaceId: target)]
            )
            let shouldPause = !["saved", "remote", "acknowledged"].contains(state)
            if shouldPause {
                #expect(throws: SyncHTTPError.self) { try database.dbQueue.write { try relocation.apply(connectionId: connection.id, in: $0) } }
            } else {
                #expect(try database.dbQueue.write { try relocation.apply(connectionId: connection.id, in: $0) })
            }
            try database.dbQueue.read { (db: Database) throws in
                let expectedWorkspace = shouldPause ? source.id : target
                #expect(try MeetingRecord.fetchOne(db, key: meeting.id)?.workspaceId == expectedWorkspace)
                #expect(try SyncTransactionQueue.hasPending(workspaceId: source.id, in: db) == (state == "transaction"))
                if state != "transaction" {
                    let archive = try #require(try RecordingArchiveRecord.fetchOne(db))
                    #expect(archive.workspaceId == expectedWorkspace)
                    #expect(archive.state == (["acknowledged", "partial"].contains(state) ? "syncing" : state))
                }
            }
        }

        @Test(arguments: ["source", "destination", "local"])
        func recordingBlocksOnlyAffectedWorkspaces(recordingWorkspace: String) throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let connection = DahliaAccountConnectionRecord(id: .v7(), origin: "https://example.com", clientID: "test", createdAt: .now)
            let source = WorkspaceRecord(
                id: .v7(), path: nil, name: "Source", createdAt: .now, lastOpenedAt: .now,
                accountConnectionId: connection.id, organizationId: .v7(), syncRole: "admin", syncConfirmedConnectionId: connection.id
            )
            var destination = source
            destination.id = .v7()
            let local = WorkspaceRecord(id: .v7(), path: nil, name: "Local", createdAt: .now, lastOpenedAt: .now)
            let meeting = MeetingRecord(id: .v7(), workspaceId: source.id, projectId: nil, name: "Move", createdAt: .now, updatedAt: .now)
            let recordingWorkspaceId = switch recordingWorkspace {
            case "source": source.id
            case "destination": destination.id
            default: local.id
            }
            let recording = MeetingRecord(
                id: .v7(), workspaceId: recordingWorkspaceId,
                projectId: nil, name: "Recording", createdAt: .now, updatedAt: .now
            )
            try database.dbQueue.write { db in
                try connection.insert(db)
                for workspace in [source, destination, local] {
                    try workspace.insert(db)
                }
                try meeting.insert(db)
                try recording.insert(db)
                try RecordingSessionRecord(id: .v7(), meetingId: recording.id, startedAt: .now, offsetSeconds: 0, createdAt: .now, updatedAt: .now)
                    .insert(db)
            }
            let relocation = WorkspaceRelocation(
                workspaces: [.init(
                    workspaceId: destination.id,
                    organizationId: destination.organizationId ?? .v7(),
                    name: "Destination",
                    createdAt: .now,
                    role: "admin"
                )],
                items: [.init(entity: .meeting, id: meeting.id, workspaceId: destination.id)]
            )
            if recordingWorkspace == "local" {
                #expect(try database.dbQueue.write { try relocation.apply(connectionId: connection.id, in: $0) })
            } else {
                #expect(throws: SyncHTTPError.self) { try database.dbQueue.write { try relocation.apply(connectionId: connection.id, in: $0) } }
            }
            try database.dbQueue.read { db throws in
                #expect(try MeetingRecord.fetchOne(db, key: meeting.id)?.workspaceId == (recordingWorkspace == "local" ? destination.id : source.id))
                #expect(try RecordingSessionRecord.fetchOne(db)?.endedAt == nil)
                #expect(try RecordingSessionRecord.fetchCount(db) == 1)
            }
        }

    }
#endif
