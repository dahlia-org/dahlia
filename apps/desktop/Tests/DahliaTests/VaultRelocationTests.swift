#if canImport(Testing)
    import Foundation
    import GRDB
    import Testing
    @testable import Dahlia

    @MainActor
    struct VaultRelocationTests {
        @Test(arguments: [false, true])
        func preservesRecordingAndIDsWithEitherVaultLoadedFirst(destinationExists: Bool) throws {
            let queue = try DatabaseQueue()
            try AppDatabaseManager.migrator.migrate(queue, upTo: "v51_collectionAppearance")
            let connection = DahliaAccountConnectionRecord(id: .v7(), origin: "https://example.com", clientID: "test", createdAt: .now)
            let source = VaultRecord(
                id: .v7(),
                path: "/tmp/source",
                name: "Source",
                createdAt: .now,
                lastOpenedAt: .now,
                accountConnectionId: connection.id,
                syncConfirmedConnectionId: connection.id
            )
            let destination = VaultRecord(
                id: .v7(),
                path: nil,
                name: "Destination",
                createdAt: .now,
                lastOpenedAt: .now,
                accountConnectionId: connection.id,
                syncConfirmedConnectionId: connection.id
            )
            let root = ProjectRecord(id: .v7(), vaultId: source.id, parentProjectId: nil, name: "Root", createdAt: .now, projectType: .undefined)
            let child = ProjectRecord(id: .v7(), vaultId: source.id, parentProjectId: root.id, name: "Child", createdAt: .now, projectType: nil)
            let meeting = MeetingRecord(id: .v7(), vaultId: source.id, projectId: child.id, name: "Recorded", createdAt: .now, updatedAt: .now)
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
            let relocation = VaultRelocation(
                vaults: [.init(vaultId: destination.id, name: destination.name, createdAt: .now, role: "owner")],
                items: [
                    .init(entity: .meeting, id: meeting.id, vaultId: destination.id),
                    .init(entity: .project, id: child.id, vaultId: destination.id),
                    .init(entity: .project, id: root.id, vaultId: destination.id),
                ]
            )
            #expect(try queue.write { try relocation.apply(connectionId: connection.id, in: $0) })
            #expect(try !queue.write { try relocation.apply(connectionId: connection.id, in: $0) })
            try queue.read { (db: Database) throws in
                #expect(try MeetingRecord.fetchOne(db, key: meeting.id)?.vaultId == destination.id)
                #expect(try ProjectRecord.fetchOne(db, key: child.id)?.parentProjectId == root.id)
                #expect(try RecordingSessionRecord.fetchOne(db, key: session.id)?.meetingId == meeting.id)
                #expect(try String.fetchOne(db, sql: "SELECT originalVaultPath FROM recording_audio_files") == "/tmp/source")
                #expect(try String.fetchOne(db, sql: "SELECT relativePath FROM recording_audio_files") == "audio.caf")
                #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
            }
        }

        @Test(arguments: ["transaction", "pending", "failed", "syncing", "saved", "remote", "acknowledged", "partial"])
        func pendingChangesStopRelocationWithoutDiscardingData(state: String) throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let connection = DahliaAccountConnectionRecord(id: .v7(), origin: "https://example.com", clientID: "test", createdAt: .now)
            let source = VaultRecord(
                id: .v7(),
                path: nil,
                name: "Source",
                createdAt: .now,
                lastOpenedAt: .now,
                accountConnectionId: connection.id,
                syncConfirmedConnectionId: connection.id
            )
            let meeting = MeetingRecord(id: .v7(), vaultId: source.id, projectId: nil, name: "Local", createdAt: .now, updatedAt: .now)
            let target = UUID.v7()
            try database.dbQueue.write { db in
                try connection.insert(db)
                try source.insert(db)
                try meeting.insert(db)
                if state == "transaction" {
                    try SyncTransactionRecorder.record(
                        vaultId: source.id,
                        operations: [SyncInitialSnapshotBuilder.vaultOperation(source, action: .update)],
                        in: db
                    )
                } else {
                    let session = RecordingSessionRecord(
                        id: .v7(), meetingId: meeting.id, startedAt: .now, endedAt: .now,
                        duration: 1, offsetSeconds: 0, createdAt: .now, updatedAt: .now
                    )
                    try session.insert(db)
                    var archive = RecordingArchiveRecord(
                        sessionId: session.id, meetingId: meeting.id, vaultId: source.id,
                        connectionId: connection.id, state: ["acknowledged", "partial"].contains(state) ? "syncing" : state
                    )
                    if state == "acknowledged" || state == "partial" {
                        archive.number = 1
                        let manifest = RecordingArchiveManifest(sampleRate: 16000, frameCount: 1, ranges: [])
                        let prepared = RecordingArchiveEncoder.Prepared(relativePath: "audio.m4a", size: 1, checksum: "checksum", manifest: manifest)
                        let audio = RecordingArchivedAudio(contentType: "audio/mp4", size: 1, checksum: "checksum", contentURL: "/audio", manifest: manifest)
                        archive.preparedJSON = String(decoding: try SyncJSON.encoder.encode(["mic": prepared, "system": prepared]), as: UTF8.self)
                        archive.audioJSON = String(decoding: try SyncJSON.encoder.encode(state == "partial" ? ["mic": audio] : ["mic": audio, "system": audio]), as: UTF8.self)
                    }
                    try archive.insert(db)
                }
            }
            let relocation = VaultRelocation(
                vaults: [.init(vaultId: target, name: "Destination", createdAt: .now, role: "owner")],
                items: [.init(entity: .meeting, id: meeting.id, vaultId: target)]
            )
            let shouldPause = !["saved", "remote", "acknowledged"].contains(state)
            if shouldPause {
                #expect(throws: SyncHTTPError.self) { try database.dbQueue.write { try relocation.apply(connectionId: connection.id, in: $0) } }
            } else {
                #expect(try database.dbQueue.write { try relocation.apply(connectionId: connection.id, in: $0) })
            }
            try database.dbQueue.read { (db: Database) throws in
                let expectedVault = shouldPause ? source.id : target
                #expect(try MeetingRecord.fetchOne(db, key: meeting.id)?.vaultId == expectedVault)
                #expect(try SyncTransactionQueue.hasPending(vaultId: source.id, in: db) == (state == "transaction"))
                if state != "transaction" {
                    let archive = try #require(try RecordingArchiveRecord.fetchOne(db))
                    #expect(archive.vaultId == expectedVault)
                    #expect(archive.state == (["acknowledged", "partial"].contains(state) ? "syncing" : state))
                }
            }
        }

        @Test(arguments: ["none", "organization", "contact", "participant", "insightProject", "insightMeeting", "topicProject", "topicMeeting"])
        func localRelationshipsPauseRelocationUntilResolved(reference: String) throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let connection = DahliaAccountConnectionRecord(id: .v7(), origin: "https://example.com", clientID: "test", createdAt: .now)
            let source = VaultRecord(
                id: .v7(), path: nil, name: "Source", createdAt: .now, lastOpenedAt: .now,
                accountConnectionId: connection.id, syncConfirmedConnectionId: connection.id
            )
            let project = ProjectRecord(id: .v7(), vaultId: source.id, parentProjectId: nil, name: "Project", createdAt: .now, projectType: .undefined)
            let meeting = MeetingRecord(id: .v7(), vaultId: source.id, projectId: project.id, name: "Meeting", createdAt: .now, updatedAt: .now)
            let contact = UUID.v7(), organization = UUID.v7(), insight = UUID.v7(), topic = UUID.v7(), target = UUID.v7()
            try database.dbQueue.write { db in
                try connection.insert(db)
                try source.insert(db)
                try project.insert(db)
                try meeting.insert(db)
                try ContactRecord(id: contact, vaultId: source.id, email: "test@example.com", displayName: "Contact", revision: 1, createdAt: .now, updatedAt: .now).insert(db)
                try OrganizationRecord(
                    id: organization, vaultId: source.id, parentOrganizationId: nil, nodeKind: .organization,
                    name: "Organization", revision: 1, createdAt: .now, updatedAt: .now
                ).insert(db)
                try InsightRecord(id: insight, vaultId: source.id, content: "Insight", isAccepted: false, metadataJSON: "{}", revision: 1, createdAt: .now, updatedAt: .now).insert(db)
                try ConversationTopicRecord(id: topic, vaultId: source.id, title: "Topic", currentState: "Open", revision: 1, createdAt: .now, updatedAt: .now).insert(db)
                switch reference {
                case "organization", "contact":
                    try ProjectResourceReferenceRecord(
                        id: .v7(), projectId: project.id, resourceType: reference == "contact" ? .contact : .organization,
                        resourceId: reference == "contact" ? contact : organization, relationLabel: "", createdAt: .now, updatedAt: .now
                    ).insert(db)
                case "participant":
                    try MeetingParticipantRecord(meetingId: meeting.id, contactId: contact, role: .attendee, responseStatus: .accepted, source: "calendar", createdAt: .now, updatedAt: .now).insert(db)
                case "insightProject", "insightMeeting":
                    try InsightReferenceRecord(
                        insightId: insight, resourceType: reference == "insightProject" ? .project : .meeting,
                        resourceId: reference == "insightProject" ? project.id : meeting.id, referenceRole: .context, createdAt: .now
                    ).insert(db)
                case "topicProject", "topicMeeting":
                    try ConversationTopicReferenceRecord(
                        topicId: topic, resourceType: reference == "topicProject" ? .project : .meeting,
                        resourceId: reference == "topicProject" ? project.id : meeting.id,
                        note: reference == "topicMeeting" ? "Discussed" : nil, createdAt: .now, updatedAt: .now
                    ).insert(db)
                default: break
                }
            }
            let relocation = VaultRelocation(
                vaults: [.init(vaultId: target, name: "Destination", createdAt: .now, role: "owner")],
                items: [.init(entity: .project, id: project.id, vaultId: target), .init(entity: .meeting, id: meeting.id, vaultId: target)]
            )
            if reference != "none" {
                #expect(throws: SyncHTTPError.self) { try database.dbQueue.write { try relocation.apply(connectionId: connection.id, in: $0) } }
                try database.dbQueue.read { db throws in
                    #expect(try ProjectRecord.fetchOne(db, key: project.id)?.vaultId == source.id)
                    #expect(try MeetingRecord.fetchOne(db, key: meeting.id)?.vaultId == source.id)
                    #expect(try !SyncTransactionQueue.hasPending(vaultId: source.id, in: db))
                    #expect(try VaultRecord.fetchOne(db, key: target) == nil)
                }
                try database.dbQueue.write { db in
                    for table in ["project_resource_references", "meeting_participants", "insight_references", "conversation_topic_references"] {
                        try db.execute(sql: "DELETE FROM \(table)")
                    }
                }
            }
            #expect(try database.dbQueue.write { try relocation.apply(connectionId: connection.id, in: $0) })
            try database.dbQueue.read { db throws in
                #expect(try MeetingRecord.fetchOne(db, key: meeting.id)?.vaultId == target)
                #expect(try ContactRecord.fetchOne(db, key: contact)?.vaultId == source.id)
                #expect(try OrganizationRecord.fetchOne(db, key: organization)?.vaultId == source.id)
                #expect(try InsightRecord.fetchOne(db, key: insight)?.vaultId == source.id)
                #expect(try ConversationTopicRecord.fetchOne(db, key: topic)?.vaultId == source.id)
                #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
            }
        }
    }
#endif
