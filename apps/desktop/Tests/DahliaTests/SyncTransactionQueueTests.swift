#if canImport(Testing)
    import DahliaMeetingAccess
    import DahliaRuntimeSupport
    import Foundation
    import GRDB
    import Testing
    @testable import Dahlia

    @MainActor
    struct SyncTransactionQueueTests {
        @Test(arguments: ["", "20260903T000000Z"])
        func uploadsCalendarOccurrenceIdentity(recurrenceId: String) async throws {
            let (database, workspace) = try await syncedDatabase()
            let start = try Date("2026-09-03T09:00:00+09:00", strategy: .iso8601)
            let end = start.addingTimeInterval(3600)
            try await database.dbQueue.write { db in
                try db.execute(sql: """
                INSERT INTO calendar_events(ical_uid, recurrence_id, created_at, updated_at, title, start, "end", is_all_day)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: ["shared@example.com", recurrenceId, start, start, "Calendar", start, end, recurrenceId.isEmpty])
                var meeting = MeetingRecord(
                    id: .v7(), workspaceId: workspace.id, name: "Meeting", createdAt: start, updatedAt: start,
                    calendarEventIcalUid: "shared@example.com", calendarEventRecurrenceId: recurrenceId
                )
                for action in [SyncAction.create, .update] {
                    let operation = try SyncInitialSnapshotBuilder.meetingOperation(meeting, action: action, in: db)
                    let data = try #require(operation.payloadJSON)
                    let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
                    #expect(body["icalUid"] as? String == "shared@example.com")
                    #expect(body["recurrenceId"] as? String == recurrenceId)
                    let event = try #require(body["calendarEvent"] as? [String: Any])
                    #expect(Set(event.keys) == ["start", "end", "is_all_day", "attendees"])
                    #expect((event["attendees"] as? [Any])?.isEmpty == true)
                    #expect(event["start"] as? String == start.ISO8601Format())
                    #expect(event["end"] as? String == end.ISO8601Format())
                    #expect(event["is_all_day"] as? Bool == recurrenceId.isEmpty)
                }
                meeting.calendarEventIcalUid = nil
                meeting.calendarEventRecurrenceId = nil
                let operation = try SyncInitialSnapshotBuilder.meetingOperation(meeting, action: .update, in: db)
                let data = try #require(operation.payloadJSON)
                let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
                #expect(body["icalUid"] == nil)
                #expect(body["recurrenceId"] == nil)
                #expect(body["calendarEvent"] == nil)
            }
        }

        @Test
        func collectionAppearanceRoundTripsThroughCanonicalStorageAndUpload() async throws {
            let (database, workspace) = try await syncedDatabase()
            let project = ProjectRecord(
                id: .v7(),
                workspaceId: workspace.id,
                parentProjectId: nil,
                name: "Project",
                createdAt: .now,
                projectType: .undefined
            )
            let payload = try SyncJSON.decoder.decode(
                SyncCanonicalPayload.self,
                from: Data(
                    #"{"name":"Styled","createdAt":"2026-09-09T00:00:00Z","projectType":"undefined","icon":"book.closed","color":"green"}"#
                        .utf8
                )
            )
            let renamed = try SyncJSON.decoder.decode(
                SyncCanonicalPayload.self,
                from: Data(
                    #"{"name":"Renamed","createdAt":"2026-09-09T00:00:00Z","projectType":"undefined","icon":"book.closed","color":"green"}"#
                        .utf8
                )
            )
            try await database.dbQueue.write { db in
                try project.insert(db)
                for (entity, id) in [(SyncEntity.workspace, workspace.id), (.project, project.id)] {
                    try SyncTransactionQueue.applyCanonical(entity, id: id, workspaceId: workspace.id, value: payload, in: db)
                    try SyncTransactionQueue.applyCanonical(entity, id: id, workspaceId: workspace.id, value: renamed, in: db)
                }
            }
            let (savedWorkspace, savedProject) = try await database.dbQueue.read { db in
                try (WorkspaceRecord.fetchOne(db, key: workspace.id), ProjectRecord.fetchOne(db, key: project.id))
            }
            let storedWorkspace = try #require(savedWorkspace)
            let storedProject = try #require(savedProject)
            #expect(storedWorkspace.appearance?.icon.rawValue == "book.closed")
            #expect(storedWorkspace.appearance?.color.rawValue == "green")
            #expect(storedProject.appearance == storedWorkspace.appearance)
            for operation in try [
                SyncInitialSnapshotBuilder.workspaceOperation(storedWorkspace, action: .update),
                SyncInitialSnapshotBuilder.projectOperation(storedProject, action: .update),
            ] {
                let data = try #require(operation.payloadJSON)
                let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
                #expect(body["icon"] as? String == "book.closed")
                #expect(body["color"] as? String == "green")
            }
        }

        @Test(arguments: [false, true])
        func canonicalProjectAbsenceClearsLocalAppearance(useSnapshot: Bool) async throws {
            let (database, workspace) = try await syncedDatabase()
            let project = ProjectRecord(
                id: .v7(), workspaceId: workspace.id, parentProjectId: nil, name: "Project",
                createdAt: Date(timeIntervalSince1970: 1000), projectType: .undefined,
                appearance: ProjectAppearance(icon: .book, color: .green)
            )
            try await database.dbQueue.write { db in try project.insert(db) }
            if useSnapshot {
                #expect(try await RemoteChangeApplier.reconcileProjectSnapshot([
                    .init(
                        icon: nil, color: nil,
                        projectId: project.id,
                        parentProjectId: nil,
                        name: project.name,
                        description: "",
                        projectType: "undefined",
                        revision: 2,
                        createdAt: project.createdAt
                    ),
                ], workspaceId: workspace.id, expectedConnectionId: #require(workspace.syncConfirmedConnectionId), dbQueue: database.dbQueue))
            } else {
                let canonical = try SyncJSON.decoder.decode(
                    SyncCanonicalPayload.self,
                    from: Data(#"{"name":"Project","createdAt":"1970-01-01T00:16:40Z","projectType":"undefined","icon":null,"color":null}"#
                        .utf8)
                )
                try await database.dbQueue.write { db in
                    try SyncTransactionQueue.applyCanonical(.project, id: project.id, workspaceId: workspace.id, value: canonical, in: db)
                }
            }
            let saved = try await database.dbQueue.read { db in try #require(try ProjectRecord.fetchOne(db, key: project.id)) }
            #expect(saved.appearance == nil)
            #expect(saved.revision == 2)
            let operation = try SyncInitialSnapshotBuilder.projectOperation(saved, action: .update)
            let data = try #require(operation.payloadJSON)
            let payload = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(payload["icon"] is NSNull)
            #expect(payload["color"] is NSNull)
        }

        @Test
        func operationBodyEncodesAbsentValuesAsExplicitNull() throws {
            let body = SyncOperationBody(
                id: .v7(),
                entity: .workspace,
                action: .create,
                entityId: .v7(),
                baseRevision: nil,
                data: nil
            )

            let encoded = try SyncJSON.encoder.encode(body)
            let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

            #expect(object.keys.contains("baseRevision"))
            #expect(object["baseRevision"] is NSNull)
            #expect(object.keys.contains("data"))
            #expect(object["data"] is NSNull)
        }

        @Test
        func canonicalProjectUpdateInvalidatesOpenEditsForItsHierarchy() async throws {
            let (database, workspace) = try await syncedDatabase()
            let root = ProjectRecord(
                id: .v7(), workspaceId: workspace.id, parentProjectId: nil,
                name: "Root", createdAt: .now, projectType: .undefined
            )
            let child = ProjectRecord(
                id: .v7(), workspaceId: workspace.id, parentProjectId: root.id,
                name: "Child", createdAt: .now, projectType: nil
            )
            let canonical = try SyncJSON.decoder.decode(
                SyncCanonicalPayload.self,
                from: Data(
                    "{\"name\":\"Renamed\",\"description\":\"Remote\",\"projectType\":\"undefined\",\"createdAt\":\"2026-09-03T00:00:00.000Z\"}"
                        .utf8
                )
            )
            try await database.dbQueue.write { db in
                try root.insert(db)
                try child.insert(db)
                try SyncTransactionQueue.applyCanonical(
                    .project,
                    id: root.id,
                    workspaceId: workspace.id,
                    value: canonical,
                    in: db
                )
            }

            let revisions = try await database.dbQueue.read { db in
                try (
                    ProjectRecord.fetchOne(db, key: root.id)?.revision,
                    ProjectRecord.fetchOne(db, key: child.id)?.revision
                )
            }
            #expect(revisions.0 == 2)
            #expect(revisions.1 == 2)
        }

        @Test
        func retryingAValidationBlockPreservesTheImmutableTransaction() async throws {
            let (database, workspace) = try await syncedDatabase()
            let payload = try SyncJSON.encoder.encode(JSONValue.object(["name": .string("Queued")]))
            let operationId = UUID.v7()
            _ = try await database.dbQueue.write { db in
                try SyncTransactionRecorder.record(
                    workspaceId: workspace.id,
                    operations: [SyncOperationDraft(
                        id: operationId,
                        entity: .workspace,
                        action: .update,
                        entityId: workspace.id,
                        payloadJSON: payload
                    )],
                    in: db
                )
            }
            let firstClaim = try #require(try await SyncTransactionQueue.claim(dbQueue: database.dbQueue))
            try await SyncTransactionQueue.block(
                firstClaim,
                reason: .validation,
                response: Data(#"{"error":"invalid_sync_transaction"}"#.utf8),
                dbQueue: database.dbQueue
            )

            try await SyncTransactionQueue.retryInvalidTransaction(workspaceId: workspace.id, dbQueue: database.dbQueue)

            let retried = try #require(try await SyncTransactionQueue.claim(dbQueue: database.dbQueue))
            #expect(retried.id == firstClaim.id)
            #expect(retried.operations.first?.id == operationId)
            #expect(retried.operations.first?.payloadJSON == payload)
        }

        @Test
        func interruptedInitialSnapshotRepairsOnlyAnUnconfirmedOwnerWorkspace() async throws {
            let (database, workspace) = try await syncedDatabase()

            try await SyncInitialSnapshotBuilder.enqueuePending(dbQueue: database.dbQueue)

            let ownerState: (UUID?, Row?) = try database.dbQueue.read { db in
                let savedWorkspace = try WorkspaceRecord.fetchOne(db, key: workspace.id)
                let operation = try Row.fetchOne(
                    db,
                    sql: """
                    SELECT o.entity, o.action FROM sync_operations o
                    JOIN sync_transactions t ON t.id = o.transactionId
                    WHERE t.workspace_id = ? ORDER BY t.sequence, o.position LIMIT 1
                    """,
                    arguments: [workspace.id]
                )
                return (savedWorkspace?.syncConfirmedConnectionId, operation)
            }
            #expect(ownerState.0 == workspace.accountConnectionId)
            #expect(ownerState.1?["entity"] as String? == "workspace")
            #expect(ownerState.1?["action"] as String? == "create")

            let memberWorkspaceId = UUID.v7()
            try await database.dbQueue.write { db in
                var member = WorkspaceRecord(
                    id: memberWorkspaceId,
                    path: "/tmp/member",
                    name: "Member",
                    createdAt: .now,
                    lastOpenedAt: .now
                )
                member.accountConnectionId = workspace.accountConnectionId
                if member.syncRole == nil { member.syncRole = "admin" }
                if member.organizationId == nil { member.organizationId = .v7() }
                member.syncConfirmedConnectionId = workspace.accountConnectionId
                member.syncRole = "viewer"
                try member.insert(db)
            }

            try await SyncInitialSnapshotBuilder.enqueuePending(dbQueue: database.dbQueue)

            let memberState: (UUID?, Int?) = try await database.dbQueue.read { db in
                let savedWorkspace = try WorkspaceRecord.fetchOne(db, key: memberWorkspaceId)
                let transactionCount = try Int.fetchOne(
                    db,
                    sql: "SELECT count(*) FROM sync_transactions WHERE workspace_id = ?",
                    arguments: [memberWorkspaceId]
                )
                return (savedWorkspace?.syncConfirmedConnectionId, transactionCount)
            }
            #expect(memberState.0 == workspace.accountConnectionId)
            #expect(memberState.1 == 0)
        }

        @Test
        func initialSnapshotRepairLeavesAnExistingOwnerTransactionUntouched() async throws {
            let (database, workspace) = try await syncedDatabase()
            _ = try await database.dbQueue.write { db in
                try SyncTransactionRecorder.record(
                    workspaceId: workspace.id,
                    operations: [SyncOperationDraft(entity: .workspace, action: .update, entityId: workspace.id)],
                    in: db
                )
            }

            try await SyncInitialSnapshotBuilder.enqueuePending(dbQueue: database.dbQueue)

            let operations = try await database.dbQueue.read { db in
                try Row.fetchAll(
                    db,
                    sql: """
                    SELECT o.action FROM sync_operations o
                    JOIN sync_transactions t ON t.id = o.transactionId
                    WHERE t.workspace_id = ? ORDER BY t.sequence, o.position
                    """,
                    arguments: [workspace.id]
                ).map { $0["action"] as String }
            }
            #expect(operations == ["update"])
        }

        @Test
        func nonConflictBlocksCannotDiscardDurableTransactions() async throws {
            let (database, workspace) = try await syncedDatabase()
            _ = try await database.dbQueue.write { db in
                try SyncTransactionRecorder.record(
                    workspaceId: workspace.id,
                    operations: [SyncOperationDraft(entity: .workspace, action: .update, entityId: workspace.id)],
                    in: db
                )
            }
            let claimed = try #require(try await SyncTransactionQueue.claim(dbQueue: database.dbQueue))
            try await SyncTransactionQueue.block(
                claimed,
                reason: .validation,
                response: Data("{}".utf8),
                dbQueue: database.dbQueue
            )

            try await SyncTransactionQueue.acceptServerVersion(workspaceId: workspace.id, dbQueue: database.dbQueue)
            try await SyncTransactionQueue.reapplyLocalVersion(workspaceId: workspace.id, dbQueue: database.dbQueue)

            #expect(try await database.dbQueue.read { db in
                try Int.fetchOne(db, sql: "SELECT count(*) FROM sync_transactions WHERE workspace_id = ?", arguments: [workspace.id])
            } == 1)

            try await SyncTransactionQueue.discardInvalidTransaction(workspaceId: workspace.id, dbQueue: database.dbQueue)
            let replacement = try #require(try await SyncTransactionQueue.claim(dbQueue: database.dbQueue))
            #expect(replacement.workspaceId == workspace.id)
            #expect(replacement.operations.count == 1)
            #expect(replacement.operations.first?.entity == .workspace)
            #expect(replacement.operations.first?.action == .create)
        }

        @Test
        func authorizationBlocksCanRetryAfterReauthentication() async throws {
            let (database, workspace) = try await syncedDatabase()
            _ = try await database.dbQueue.write { db in
                try SyncTransactionRecorder.record(
                    workspaceId: workspace.id,
                    operations: [SyncOperationDraft(entity: .workspace, action: .update, entityId: workspace.id)],
                    in: db
                )
            }
            let firstClaim = try #require(try await SyncTransactionQueue.claim(dbQueue: database.dbQueue))
            try await SyncTransactionQueue.block(
                firstClaim,
                reason: .authorization,
                response: Data("{}".utf8),
                dbQueue: database.dbQueue
            )

            try await SyncTransactionQueue.retryAuthorizationBlocks(
                connectionId: firstClaim.connectionId,
                dbQueue: database.dbQueue
            )

            let retried = try #require(try await SyncTransactionQueue.claim(dbQueue: database.dbQueue))
            #expect(retried.id == firstClaim.id)
        }

        @Test
        func restoreResetKeepsTheConfirmedWorkspaceRevisionInItsImmutableOperation() async throws {
            let (database, workspace) = try await syncedDatabase()
            try await database.dbQueue.write { db in
                try db.execute(
                    sql: "INSERT INTO sync_entity_state(workspace_id, entity, entityId, confirmedRevision) VALUES (?, 'workspace', ?, 4)",
                    arguments: [workspace.id, workspace.id]
                )
            }

            try await SyncInitialSnapshotBuilder.prepareRestore(dbQueue: database.dbQueue)
            try await SyncInitialSnapshotBuilder.enqueuePending(dbQueue: database.dbQueue)

            let state = try await database.dbQueue.read { db in
                try (
                    Int.fetchOne(
                        db,
                        sql: "SELECT baseRevision FROM sync_operations WHERE entity = 'workspace' AND action = 'reset'"
                    ),
                    Int.fetchOne(db, sql: "SELECT count(*) FROM sync_entity_state WHERE workspace_id = ?", arguments: [workspace.id])
                )
            }
            #expect(state.0 == 4)
            #expect(state.1 == 0)
        }

        @Test
        func ignoresReceiptThatReturnsAfterWorkspaceMovesToLocalAccount() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let connection = DahliaAccountConnectionRecord(
                id: .v7(), origin: "https://server.example.com", clientID: "desktop-client", createdAt: .now
            )
            var workspace = WorkspaceRecord(id: .v7(), path: "/tmp/sync", name: "Sync", createdAt: .now, lastOpenedAt: .now)
            workspace.accountConnectionId = connection.id
            if workspace.syncRole == nil { workspace.syncRole = "admin" }
            if workspace.organizationId == nil { workspace.organizationId = .v7() }
            workspace.syncConfirmedConnectionId = connection.id
            let savedWorkspace = workspace
            try await database.dbQueue.write { db in
                try connection.insert(db)
                try savedWorkspace.insert(db)
                try db.execute(
                    sql: "INSERT INTO sync_entity_state(workspace_id, entity, entityId, confirmedRevision) VALUES (?, 'workspace', ?, 3)",
                    arguments: [savedWorkspace.id, savedWorkspace.id]
                )
            }
            let repository = MeetingRepository(dbQueue: database.dbQueue)
            _ = try await repository.updateWorkspaceName(id: savedWorkspace.id, name: "Sent name")
            let claimed = try #require(try await SyncTransactionQueue.claim(dbQueue: database.dbQueue))

            // Simulate a completed detach so the delayed receipt exercises the association guard.
            try await database.dbQueue.write { db in
                try SyncTransactionQueue.discard(workspaceId: savedWorkspace.id, in: db)
                try db.execute(sql: "DELETE FROM sync_entity_state WHERE workspace_id = ?", arguments: [savedWorkspace.id])
                try db.execute(
                    sql: "UPDATE workspaces SET accountConnectionId = NULL, organizationId = NULL, syncConfirmedConnectionId = NULL, syncPullCursor = NULL WHERE id = ?",
                    arguments: [savedWorkspace.id]
                )
            }
            _ = try await repository.updateWorkspaceName(id: savedWorkspace.id, name: "Local after sign out")
            try await SyncTransactionQueue.complete(
                claimed,
                response: SyncTransactionResponse(
                    id: claimed.id,
                    status: "committed",
                    cursor: "late-cursor",
                    records: [.init(
                        entity: .workspace,
                        id: savedWorkspace.id,
                        revision: 4,
                        record: .object(["name": .string("Late canonical name")])
                    )]
                ),
                dbQueue: database.dbQueue
            )

            let state = try await database.dbQueue.read { db in
                try (
                    WorkspaceRecord.fetchOne(db, key: savedWorkspace.id),
                    Int.fetchOne(db, sql: "SELECT count(*) FROM sync_transactions WHERE workspace_id = ?", arguments: [savedWorkspace.id]),
                    Int.fetchOne(db, sql: "SELECT count(*) FROM sync_entity_state WHERE workspace_id = ?", arguments: [savedWorkspace.id])
                )
            }
            #expect(state.0?.name == "Local after sign out")
            #expect(state.0?.accountConnectionId == nil)
            #expect(state.0?.syncLastCommittedCursor == nil)
            #expect(state.1 == 0)
            #expect(state.2 == 0)
        }

        @Test(arguments: [false, true])
        func acceptingServerVersionForcesCanonicalReconciliation(hasConfirmedWorkspace: Bool) async throws {
            let (database, workspace) = try await syncedDatabase()
            try await database.dbQueue.write { db in
                if hasConfirmedWorkspace {
                    try db.execute(
                        sql: "INSERT INTO sync_entity_state(workspace_id, entity, entityId, confirmedRevision) VALUES (?, 'workspace', ?, 3)",
                        arguments: [workspace.id, workspace.id]
                    )
                }
                var edited = workspace
                edited.name = "Rejected local name"
                edited.appearance = ProjectAppearance(icon: .book, color: .green)
                try edited.update(db)
                try SyncTransactionRecorder.record(
                    workspaceId: workspace.id,
                    operations: [SyncInitialSnapshotBuilder.workspaceOperation(edited, action: hasConfirmedWorkspace ? .update : .create)],
                    in: db
                )
            }
            let claimed = try #require(try await SyncTransactionQueue.claim(dbQueue: database.dbQueue))
            try await SyncTransactionQueue.block(
                claimed,
                reason: .conflict,
                response: Data("""
                {"conflicts":[{"entity":"workspace","id":"\(workspace.id.uuidString)","serverRevision":4}]}
                """.utf8),
                dbQueue: database.dbQueue
            )

            try await SyncTransactionQueue.acceptServerVersion(workspaceId: workspace.id, dbQueue: database.dbQueue)

            let state = try await database.dbQueue.read { db in
                try (
                    Int.fetchOne(db, sql: "SELECT count(*) FROM sync_transactions WHERE workspace_id = ?", arguments: [workspace.id]),
                    Int.fetchOne(db, sql: "SELECT count(*) FROM sync_entity_state WHERE workspace_id = ?", arguments: [workspace.id]),
                    WorkspaceRecord.fetchOne(db, key: workspace.id)?.syncPullCursor
                )
            }
            #expect(state.0 == 0)
            #expect(state.1 == 1)
            #expect(state.2 == nil)
            try await SyncInitialSnapshotBuilder.enqueuePending(dbQueue: database.dbQueue)
            #expect(try await SyncTransactionQueue.claim(dbQueue: database.dbQueue) == nil)
            #expect(try await database.dbQueue.read { db in
                try WorkspaceRecord.fetchOne(db, key: workspace.id)?.syncConfirmedConnectionId
            } == workspace.syncConfirmedConnectionId)

            let canonical = try SyncJSON.decoder.decode(
                SyncCanonicalPayload.self,
                from: Data(#"{"name":"Server name","icon":null,"color":null}"#.utf8)
            )
            let changes: [SyncChangePage.Change] = [
                .init(sequence: 4, entity: .workspace, entityId: workspace.id, action: "upsert", revision: 4, record: canonical),
            ]
            #expect(try await RemoteChangeApplier.apply(
                changes, screenshots: [:], transcripts: [:], cursor: nil,
                workspaceId: workspace.id, expectedConnectionId: #require(workspace.syncConfirmedConnectionId),
                dbQueue: database.dbQueue
            ))
            #expect(try await RemoteChangeApplier.finishReset(
                SyncResetSnapshot(canonicalChanges: changes), cursor: "server-cursor",
                workspaceId: workspace.id, expectedConnectionId: #require(workspace.syncConfirmedConnectionId),
                dbQueue: database.dbQueue
            ))
            try await SyncInitialSnapshotBuilder.enqueuePending(dbQueue: database.dbQueue)
            #expect(try await SyncTransactionQueue.claim(dbQueue: database.dbQueue) == nil)
            #expect(try await database.dbQueue.read { db in
                try WorkspaceRecord.fetchOne(db, key: workspace.id)?.name
            } == "Server name")
            #expect(try await database.dbQueue.read { db in
                try WorkspaceRecord.fetchOne(db, key: workspace.id)?.appearance
            } == nil)
        }

        @Test
        func reconciliationRebasesDurableEditsBeforeTheyCanBeClaimed() async throws {
            let (database, workspace) = try await syncedDatabase()
            let connectionId = try #require(workspace.syncConfirmedConnectionId)
            _ = try await database.dbQueue.write { db in
                try SyncTransactionRecorder.record(
                    workspaceId: workspace.id,
                    operations: [SyncInitialSnapshotBuilder.workspaceOperation(workspace, action: .update)], in: db
                )
            }
            let rejected = try #require(try await SyncTransactionQueue.claim(dbQueue: database.dbQueue))
            try await SyncTransactionQueue.block(rejected, reason: .conflict, response: Data("{}".utf8), dbQueue: database.dbQueue)
            try await SyncTransactionQueue.acceptServerVersion(workspaceId: workspace.id, dbQueue: database.dbQueue)

            let meetingId = UUID.v7()
            let patch = SyncOperationDraft(entity: .transcript, action: .patch, entityId: meetingId)
            let segment = SyncTranscriptPatchSegment(TranscriptContent(
                id: .v7(), meetingId: meetingId, sessionId: nil, startTime: .now, endTime: nil,
                text: "Finalized during reconciliation", translatedText: nil, isConfirmed: true,
                audioSource: "mic", speakerLabel: nil, audioFeatureVersion: nil,
                audioActiveRmsDecibels: nil, audioMedianPitchHertz: nil,
                audioVoicedFrameRatio: nil, audioPitchSpreadHertz: nil
            ))
            try await database.dbQueue.write { db in
                for name in ["First edit", "Second edit"] {
                    var edited = workspace
                    edited.name = name
                    try edited.update(db)
                    try SyncTransactionRecorder.record(
                        workspaceId: workspace.id,
                        operations: [SyncInitialSnapshotBuilder.workspaceOperation(edited, action: .update)], in: db
                    )
                }
                try SyncTransactionRecorder.record(
                    workspaceId: workspace.id, operations: [patch], transcriptSegments: [patch.id: [segment]], in: db
                )
            }
            #expect(try await SyncTransactionQueue.claim(dbQueue: database.dbQueue) == nil)
            await #expect(throws: SyncTransactionQueueError.self) {
                try await SyncTransactionQueue.reconcileRevisions(
                    [], workspaceId: workspace.id, connectionId: connectionId, dbQueue: database.dbQueue
                )
            }
            #expect(try await SyncTransactionQueue.claim(dbQueue: database.dbQueue) == nil)

            let canonical = try SyncJSON.decoder.decode(SyncCanonicalPayload.self, from: Data("{\"name\":\"Server\"}".utf8))
            let changes: [SyncChangePage.Change] = [
                .init(sequence: 1, entity: .workspace, entityId: workspace.id, action: "upsert", revision: 8, record: canonical),
                .init(sequence: 2, entity: .transcript, entityId: meetingId, action: "upsert", revision: 4, record: nil),
            ]
            try await SyncTransactionQueue.reconcileRevisions(
                changes, workspaceId: workspace.id, connectionId: connectionId, dbQueue: database.dbQueue
            )
            let revisions = try await database.dbQueue.read { db in
                try Int.fetchAll(db, sql: """
                SELECT o.baseRevision FROM sync_operations o JOIN sync_transactions t ON t.id = o.transactionId
                WHERE t.workspace_id = ? ORDER BY t.sequence, o.position
                """, arguments: [workspace.id])
            }
            #expect(revisions == [8, 9, 4])
            #expect(try await SyncTransactionQueue.transcriptPatch(operationId: patch.id, dbQueue: database.dbQueue).segments.first?.text == segment
                .text)
            #expect(try await database.dbQueue.read { db in
                try WorkspaceRecord.fetchOne(db, key: workspace.id)?.name
            } == "Second edit")
            let first = try #require(try await SyncTransactionQueue.claim(dbQueue: database.dbQueue))
            #expect(first.operations.first?.baseRevision == 8)
            // A pre-upgrade retry must retain its wire body even if a revision marker remains.
            try await database.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE sync_entity_state SET confirmedRevision = NULL WHERE workspace_id = ? AND entity = 'workspace'",
                    arguments: [workspace.id]
                )
            }
            try await SyncTransactionQueue.reconcileRevisions(
                [.init(sequence: 3, entity: .workspace, entityId: workspace.id, action: "upsert", revision: 20, record: canonical)],
                workspaceId: workspace.id, connectionId: connectionId, dbQueue: database.dbQueue
            )
            #expect(try await database.dbQueue.read { db in
                try Int.fetchOne(db, sql: "SELECT baseRevision FROM sync_operations WHERE transactionId = ?", arguments: [first.id])
            } == 8)
        }

        @Test
        func transcriptChunkEncodesRequiredNullableFields() throws {
            for hasValues in [false, true] {
                let segment = TranscriptChunkBody.Segment(
                    segmentId: .v7(), startedAt: Date(timeIntervalSince1970: 0),
                    endedAt: hasValues ? Date(timeIntervalSince1970: 1) : nil,
                    text: "Confirmed", createdAt: nil,
                    audioSource: hasValues ? "mic" : nil,
                    speakerLabel: hasValues ? "Speaker" : nil
                )
                let data = try SyncJSON.encoder.encode(TranscriptChunkBody(segments: [segment], deletions: []))
                let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
                let segments = try #require(object["segments"] as? [[String: Any]])
                let encoded = try #require(segments.first)
                for key in ["endedAt", "audioSource", "speakerLabel"] {
                    let value = try #require(encoded[key])
                    #expect((value is NSNull) == !hasValues)
                }
                let decoded = try SyncJSON.decoder.decode(TranscriptChunkBody.self, from: data)
                #expect(decoded.segments.first?.speakerLabel == segment.speakerLabel)
                #expect(decoded.segments.first?.audioSource == segment.audioSource)
                #expect(decoded.segments.first?.endedAt == segment.endedAt)
            }
        }

        @Test
        func summaryReceiptAcknowledgesAfterLaterMeetingDeletion() async throws {
            let (database, workspace) = try await syncedDatabase()
            let meeting = MeetingRecord(id: .v7(), workspaceId: workspace.id, projectId: nil, name: "Deleted", createdAt: .now, updatedAt: .now)
            try await database.dbQueue.write { db in
                try meeting.insert(db)
                try SyncTransactionRecorder.record(workspaceId: workspace.id, operations: [
                    SyncOperationDraft(entity: .summary, action: .upsert, entityId: meeting.id),
                ], in: db)
            }
            let sent = try #require(try await SyncTransactionQueue.claim(dbQueue: database.dbQueue))
            try MeetingRepository(dbQueue: database.dbQueue).deleteMeeting(id: meeting.id)
            let response = try SyncJSON.decoder.decode(SyncTransactionResponse.self, from: Data("""
            {"id":"\(sent.id)","status":"committed","cursor":"summary-receipt","records":[
              {"entity":"summary","id":"\(meeting.id)","revision":2,"record":{
                "title":"Summary","document":"Body","createdAt":"2026-09-06T00:00:00Z"
              }}
            ]}
            """.utf8))
            try await SyncTransactionQueue.complete(sent, response: response, dbQueue: database.dbQueue)
            #expect(try await database.dbQueue.read { try SummaryContent.fetchOne($0, key: meeting.id) } == nil)
            let next = try #require(try await SyncTransactionQueue.claim(dbQueue: database.dbQueue))
            #expect(next.operations.first?.entity == .meeting)
            #expect(next.operations.first?.action == .delete)
        }

        @Test
        func compactReceiptPreservesLaterEditAndItsBaseRevision() async throws {
            let (database, workspace) = try await syncedDatabase()
            try await database.dbQueue.write { db in
                try db.execute(
                    sql: "INSERT INTO sync_entity_state(workspace_id, entity, entityId, confirmedRevision) VALUES (?, 'workspace', ?, 3)",
                    arguments: [workspace.id, workspace.id]
                )
                try SyncTransactionRecorder.record(
                    workspaceId: workspace.id,
                    operations: [SyncInitialSnapshotBuilder.workspaceOperation(workspace, action: .update)],
                    in: db
                )
            }
            let first = try #require(try await SyncTransactionQueue.claim(dbQueue: database.dbQueue))
            try await database.dbQueue.write { db in
                var edited = workspace
                edited.name = "Newer local edit"
                try edited.update(db)
                try SyncTransactionRecorder.record(
                    workspaceId: workspace.id,
                    operations: [SyncInitialSnapshotBuilder.workspaceOperation(edited, action: .update)],
                    in: db
                )
            }
            let response = try SyncJSON.decoder.decode(SyncTransactionResponse.self, from: Data("""
            {"id":"\(first.id)","status":"committed","receipt":"compact","cursor":"old-commit","records":[{"entity":"workspace","id":"\(workspace
                .id)","revision":4}]}
            """.utf8))
            try await SyncTransactionQueue.complete(first, response: response, dbQueue: database.dbQueue)
            let canonical = try SyncJSON.decoder.decode(SyncCanonicalPayload.self, from: Data(#"{"name":"Server changed again"}"#.utf8))
            try await SyncTransactionQueue.reconcileRevisions([
                .init(sequence: 9, entity: .workspace, entityId: workspace.id, action: "upsert", revision: 9, record: canonical),
            ], workspaceId: workspace.id, connectionId: #require(workspace.syncConfirmedConnectionId), dbQueue: database.dbQueue)
            let next = try #require(try await SyncTransactionQueue.claim(dbQueue: database.dbQueue))
            #expect(next.operations.first?.baseRevision == 4)
            let saved = try await database.dbQueue.read { db in try WorkspaceRecord.fetchOne(db, key: workspace.id) }
            #expect(saved?.name == "Newer local edit")
            #expect(saved?.syncPullCursor == nil)
            #expect(saved?.syncRecoveryState == "pending")
        }

        @Test(arguments: [false, true])
        func recoveryFenceSurvivesAnEditOrReconnectEvenAfterQueueDrains(reconnect: Bool) async throws {
            let (database, workspace) = try await syncedDatabase()
            let connection = try #require(workspace.syncConfirmedConnectionId)
            let generation = try #require(try await RemoteChangeApplier.recoveryGeneration(
                workspaceId: workspace.id,
                expectedConnectionId: connection,
                dbQueue: database.dbQueue
            ))
            try await database.dbQueue.write { db in
                if reconnect {
                    try db.execute(sql: "UPDATE workspaces SET syncConfirmedConnectionId = NULL WHERE id = ?", arguments: [workspace.id])
                    try db.execute(sql: "UPDATE workspaces SET syncConfirmedConnectionId = ? WHERE id = ?", arguments: [connection, workspace.id])
                } else {
                    try SyncTransactionRecorder.record(
                        workspaceId: workspace.id,
                        operations: [SyncInitialSnapshotBuilder.workspaceOperation(workspace, action: .update)],
                        in: db
                    )
                    try db.execute(sql: "DELETE FROM sync_transactions WHERE workspace_id = ?", arguments: [workspace.id])
                }
            }
            #expect(try await RemoteChangeApplier
                .recoveryGeneration(workspaceId: workspace.id, expectedConnectionId: connection, dbQueue: database.dbQueue) != generation)
            let payload = try SyncJSON.decoder.decode(SyncCanonicalPayload.self, from: Data(#"{"name":"Stale snapshot"}"#.utf8))
            #expect(try await !RemoteChangeApplier.apply(
                [
                    .init(sequence: 1, entity: .workspace, entityId: workspace.id, action: "upsert", revision: 1, record: payload),
                ],
                screenshots: [:],
                transcripts: [:],
                cursor: nil,
                workspaceId: workspace.id,
                expectedConnectionId: connection,
                dbQueue: database.dbQueue,
                expectedMutationGeneration: generation
            ))
            #expect(try await !RemoteChangeApplier.finishReset(
                SyncResetSnapshot(ids: [.workspace: [workspace.id]]),
                cursor: "stale",
                workspaceId: workspace.id,
                expectedConnectionId: connection,
                dbQueue: database.dbQueue,
                expectedMutationGeneration: generation
            ))
            #expect(try await database.dbQueue.read { db in try WorkspaceRecord.fetchOne(db, key: workspace.id)?.name } == workspace.name)
        }

        @Test
        func snapshotStoreBoundsPagesAndMergesDeletesAndRecreation() async throws {
            let store = try SyncSnapshotStore()
            let ids = (0 ..< 105).map { _ in UUID.v7() }
            let payload = try SyncJSON.decoder.decode(SyncCanonicalPayload.self, from: Data(#"{"name":"Project"}"#.utf8))
            try await store.merge(ids.map { .init(sequence: 0, entity: .project, entityId: $0, action: "upsert", revision: 1, record: payload) })
            let first = try await store.page()
            #expect(first.count == 100)
            #expect(try await store.page(after: first.last).count == 5)
            let removed = try #require(ids.first)
            try await store.merge([.init(sequence: 1, entity: .project, entityId: removed, action: "delete", revision: nil, record: nil)])
            #expect(try await store.revisionChanges().count == 104)
            try await store.merge([.init(sequence: 2, entity: .project, entityId: removed, action: "upsert", revision: 1, record: payload)])
            #expect(try await store.revisionChanges().count == 105)
            try await store.merge([.init(sequence: 3, entity: .workspace, entityId: .v7(), action: "reset", revision: nil, record: nil)])
            #expect(try await store.page().isEmpty)
        }

        @Test(arguments: ["target", "local", "server"])
        func recordingDefersRecoveryApplicationAndCheckpoint(recordingWorkspace: String) async throws {
            let (database, workspace) = try await syncedDatabase()
            let connection = try #require(workspace.syncConfirmedConnectionId)
            let generation = try #require(try await RemoteChangeApplier.recoveryGeneration(
                workspaceId: workspace.id,
                expectedConnectionId: connection,
                dbQueue: database.dbQueue
            ))
            let meetingId = UUID.v7()
            let contentMeetingId = UUID.v7()
            try await database.dbQueue.write { db in
                var otherWorkspace = WorkspaceRecord(id: .v7(), path: nil, name: "Other", createdAt: .now, lastOpenedAt: .now)
                if recordingWorkspace == "server" {
                    otherWorkspace.accountConnectionId = connection
                    if otherWorkspace.syncRole == nil { otherWorkspace.syncRole = "admin" }
                    if otherWorkspace.organizationId == nil { otherWorkspace.organizationId = .v7() }
                    otherWorkspace.syncConfirmedConnectionId = connection
                }
                if recordingWorkspace != "target" { try otherWorkspace.insert(db) }
                try MeetingRecord(
                    id: contentMeetingId, workspaceId: workspace.id, projectId: nil, name: "Content", createdAt: .now, updatedAt: .now
                ).insert(db)
                try db.execute(
                    sql: "INSERT INTO meetings(id, workspace_id, name, createdAt, updatedAt) VALUES (?, ?, 'Recording', ?, ?)",
                    arguments: [meetingId, recordingWorkspace == "target" ? workspace.id : otherWorkspace.id, Date.now, Date.now]
                )
                try RecordingSessionRecord(
                    id: .v7(),
                    meetingId: meetingId,
                    startedAt: .now,
                    endedAt: nil,
                    duration: nil,
                    offsetSeconds: 0,
                    createdAt: .now,
                    updatedAt: .now
                ).insert(db)
            }
            let currentGeneration = try await RemoteChangeApplier
                .recoveryGeneration(workspaceId: workspace.id, expectedConnectionId: connection, dbQueue: database.dbQueue)
            #expect((currentGeneration == nil) == (recordingWorkspace == "target"))
            try await database.dbQueue.read { db in
                let source = try #require(try TextContentStore.source(entity: .summary, id: contentMeetingId, in: db))
                #expect(try TextContentStore.mayReplace(source, entity: .summary, id: contentMeetingId, in: db) == (recordingWorkspace != "target"))
                if recordingWorkspace == "target" {
                    #expect(throws: TextContentError.self) { try TextContentStore.requireWorkspaceComplete(workspaceId: workspace.id, in: db) }
                } else {
                    try TextContentStore.requireWorkspaceComplete(workspaceId: workspace.id, in: db)
                }
            }
            #expect(try await RemoteChangeApplier.finishReset(
                SyncResetSnapshot(ids: [.workspace: [workspace.id]]),
                cursor: "stale",
                workspaceId: workspace.id,
                expectedConnectionId: connection,
                dbQueue: database.dbQueue,
                expectedMutationGeneration: generation
            ) == (recordingWorkspace != "target"))
            let count = try await database.dbQueue.read { db in
                try Int.fetchOne(db, sql: "SELECT count(*) FROM meetings WHERE id = ?", arguments: [meetingId])
            }
            #expect(count == 1)
        }

        @Test
        func recoveryMigrationPreservesReleasedWorkspace() throws {
            let queue = try DatabaseQueue()
            try AppDatabaseManager.migrator.migrate(queue, upTo: "v41_vaultAISettingsBackfill")
            let id = UUID.v7()
            try queue.write { db in
                try db.execute(
                    sql: "INSERT INTO vaults(id, path, name, createdAt, lastOpenedAt) VALUES (?, '/tmp/recovery', 'Preserved', ?, ?)",
                    arguments: [id, Date.now, Date.now]
                )
            }
            try AppDatabaseManager.migrator.migrate(queue)
            try queue.read { db in
                let workspace = try #require(try WorkspaceRecord.fetchOne(db, key: id))
                #expect(workspace.name == "Preserved")
                #expect(workspace.syncPullCursor == nil)
                #expect(workspace.syncRecoveryState == nil)
                #expect(try Int.fetchOne(db, sql: "SELECT syncMutationGeneration FROM workspaces WHERE id = ?", arguments: [id]) == 0)
                #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
            }
        }

        @Test
        func recoveryRemovesMissingChildBeforeDemotingItsParent() async throws {
            let (database, workspace) = try await syncedDatabase()
            let connection = try #require(workspace.syncConfirmedConnectionId)
            let parent = UUID.v7()
            let child = UUID.v7()
            let newRoot = UUID.v7()
            try await database.dbQueue.write { db in
                try ProjectRecord(
                    id: parent,
                    workspaceId: workspace.id,
                    parentProjectId: nil,
                    name: "Parent",
                    createdAt: .now,
                    projectType: .undefined
                )
                .insert(db)
                try ProjectRecord(id: child, workspaceId: workspace.id, parentProjectId: parent, name: "Removed", createdAt: .now, projectType: nil)
                    .insert(db)
            }
            let generation = try #require(try await RemoteChangeApplier.recoveryGeneration(
                workspaceId: workspace.id,
                expectedConnectionId: connection,
                dbQueue: database.dbQueue
            ))
            #expect(try await RemoteChangeApplier.reconcileRecoveryProjects([
                .init(
                    projectId: newRoot,
                    parentProjectId: nil,
                    name: "New root",
                    description: "",
                    projectType: "undefined",
                    revision: 1,
                    createdAt: .now
                ),
                .init(projectId: parent, parentProjectId: newRoot, name: "Parent", description: "", projectType: nil, revision: 2, createdAt: .now),
            ], workspaceId: workspace.id, expectedConnectionId: connection, dbQueue: database.dbQueue, generation: generation))
            let records = try await database.dbQueue.read { db in try ProjectRecord.fetchAll(db) }
            #expect(records.count == 2)
            #expect(records.first { $0.id == parent }?.parentProjectId == newRoot)
        }

        @Test
        func snapshotChildInvalidationClearsSummaryAfterMeetingRecreation() async throws {
            let (database, workspace) = try await syncedDatabase()
            let meeting = MeetingRecord(id: .v7(), workspaceId: workspace.id, projectId: nil, name: "Meeting", createdAt: .now, updatedAt: .now)
            try await database.dbQueue.write { db in
                try meeting.insert(db)
                try SummaryContent(meetingId: meeting.id, title: "Old summary", document: "{}", createdAt: .now).insert(db)
            }
            let store = try SyncSnapshotStore()
            let old = try SyncJSON.decoder.decode(
                SyncCanonicalPayload.self,
                from: Data(#"{"title":"Old summary","document":"{}","createdAt":"2026-09-03T00:00:00.000Z"}"#.utf8)
            )
            let cleared = try SyncJSON.decoder.decode(SyncCanonicalPayload.self, from: Data(#"{"title":null,"document":null,"createdAt":null}"#.utf8))
            let canonicalMeeting = try SyncJSON.decoder.decode(
                SyncCanonicalPayload.self,
                from: Data(#"{"name":"Recreated","status":"READY","createdAt":"2026-09-03T00:00:00.000Z","updatedAt":"2026-09-03T00:00:00.000Z"}"#
                    .utf8)
            )
            try await store.merge([
                .init(sequence: 0, entity: .summary, entityId: meeting.id, action: "upsert", revision: 1, record: old),
            ])
            // The Server coalesces the child tombstone to an empty canonical summary for the new meeting.
            try await store.merge([
                .init(sequence: 4, entity: .summary, entityId: meeting.id, action: "upsert", revision: 0, record: cleared),
                .init(sequence: 5, entity: .meeting, entityId: meeting.id, action: "upsert", revision: 1, record: canonicalMeeting),
            ])
            let connection = try #require(workspace.syncConfirmedConnectionId)
            let generation = try #require(try await RemoteChangeApplier.recoveryGeneration(
                workspaceId: workspace.id,
                expectedConnectionId: connection,
                dbQueue: database.dbQueue
            ))
            #expect(try await RemoteChangeApplier.apply(
                store.page(),
                screenshots: [:],
                transcripts: [:],
                cursor: nil,
                workspaceId: workspace.id,
                expectedConnectionId: connection,
                dbQueue: database.dbQueue,
                expectedMutationGeneration: generation
            ))
            #expect(try await RemoteChangeApplier.finishReset(
                store.resetSnapshot(),
                cursor: "recreated",
                workspaceId: workspace.id,
                expectedConnectionId: connection,
                dbQueue: database.dbQueue,
                expectedMutationGeneration: generation
            ))
            #expect(try await database.dbQueue.read { db in try SummaryContent.fetchOne(db, key: meeting.id) } == nil)
            #expect(try await database.dbQueue.read { db in try WorkspaceRecord.fetchOne(db, key: workspace.id)?.syncPullCursor } == "recreated")
            #expect(try await !SyncTransactionQueue.hasPending(workspaceId: workspace.id, dbQueue: database.dbQueue))
        }

        private func syncedDatabase() async throws -> (AppDatabaseManager, WorkspaceRecord) {
            let database = try AppDatabaseManager(path: ":memory:")
            let connection = DahliaAccountConnectionRecord(
                id: .v7(), origin: "https://server.example.com", clientID: "desktop-client", createdAt: .now
            )
            var workspace = WorkspaceRecord(id: .v7(), path: "/tmp/sync", name: "Sync", createdAt: .now, lastOpenedAt: .now)
            workspace.accountConnectionId = connection.id
            if workspace.syncRole == nil { workspace.syncRole = "admin" }
            if workspace.organizationId == nil { workspace.organizationId = .v7() }
            workspace.syncConfirmedConnectionId = connection.id
            let savedWorkspace = workspace
            try await database.dbQueue.write { db in
                try connection.insert(db)
                try savedWorkspace.insert(db)
            }
            return (database, savedWorkspace)
        }
    }
#endif
