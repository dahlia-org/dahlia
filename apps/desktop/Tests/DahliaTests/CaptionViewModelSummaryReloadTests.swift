import DahliaMeetingAccess
import Foundation
import GRDB
@testable import Dahlia
@testable import DahliaRuntimeSupport

#if canImport(Testing)
    import Testing

    /// MCP ヘルパーのような別プロセスが `summaries` を書き換えたときの Summary タブ追従。
    @MainActor
    struct CaptionViewModelSummaryReloadTests {
        @Test
        func reloadPicksUpExternalSummaryChangesWithoutOverwritingTheNoteDraft() async throws {
            let context = try Self.makeContext()
            let viewModel = CaptionViewModel()
            viewModel.loadMeeting(
                context.meetingID,
                dbQueue: context.manager.dbQueue,
                projectURL: nil,
                projectId: nil,
                vaultURL: context.vaultURL
            )
            #expect(await pollUntil { viewModel.currentSummaryDocument?.title == "Original title" })

            viewModel.noteText = "Draft the user is still editing"
            try context.replaceSummary(title: "Corrected title", body: "Tanaka approved the plan")

            viewModel.reloadSummaryDocument()

            #expect(await pollUntil { viewModel.currentSummaryDocument?.title == "Corrected title" })
            #expect(viewModel.noteText == "Draft the user is still editing")
        }

        @Test
        func reloadIsIgnoredWithoutALoadedMeeting() {
            let viewModel = CaptionViewModel()
            viewModel.reloadSummaryDocument()
            #expect(viewModel.currentSummaryDocument == nil)
        }

        @Test
        func canonicalRevisionRefreshesTheOpenMeetingAndPendingStatusWithoutTouchingItsNote() async throws {
            let context = try Self.makeContext()
            defer { try? FileManager.default.removeItem(at: context.vaultURL) }
            let connection = DahliaAccountConnectionRecord(id: .v7(), origin: "https://sync.example.test", clientID: "test", createdAt: .now)
            let vaultId = try #require(try await context.manager.dbQueue.read {
                try MeetingRecord.fetchOne($0, key: context.meetingID)?.vaultId
            })
            try await context.manager.dbQueue.write { db in
                try connection.insert(db)
                try db.execute(
                    sql: "UPDATE vaults SET accountConnectionId = ?, syncConfirmedConnectionId = ?, syncPullCursor = 'ready' WHERE id = ?",
                    arguments: [connection.id, connection.id, vaultId]
                )
                try db.execute(
                    sql: "INSERT INTO sync_entity_state(vaultId, entity, entityId, confirmedRevision) VALUES (?, 'summary', ?, 1)",
                    arguments: [vaultId, context.meetingID]
                )
                for index in 0 ..< 400 {
                    try TranscriptContent(
                        id: .v7(), meetingId: context.meetingID, startTime: Date(timeIntervalSince1970: Double(index)),
                        text: "segment \(index)", isConfirmed: true
                    ).insert(db)
                }
            }
            let viewModel = CaptionViewModel()
            viewModel.loadMeeting(context.meetingID, dbQueue: context.manager.dbQueue, projectURL: nil, projectId: nil, vaultURL: context.vaultURL)
            #expect(await pollUntil { viewModel.currentSummaryDocument?.title == "Original title" && viewModel.meetingSyncState == .synced })
            #expect(await viewModel.store.loadEarlier())
            viewModel.store.setFollowingLatest(false)
            let firstVisible = try #require(viewModel.store.segments.first?.id)
            viewModel.noteText = "Keep this local draft"
            try context.replaceSummary(title: "Canonical title", body: "Updated elsewhere")
            try await context.manager.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE sync_entity_state SET confirmedRevision = 2 WHERE vaultId = ? AND entity = 'summary'",
                    arguments: [vaultId]
                )
                try db.execute(
                    sql: "INSERT INTO sync_transactions(id, vaultId, connectionId, createdAt, availableAt) VALUES (?, ?, ?, ?, ?)",
                    arguments: [UUID.v7(), vaultId, connection.id, Date(), Date()]
                )
            }
            #expect(await pollUntil { viewModel.currentSummaryDocument?.title == "Canonical title" && viewModel.meetingSyncState == .pending })
            #expect(viewModel.noteText == "Keep this local draft")
            #expect(await pollUntil { !viewModel.store.isLoadingPage })
            #expect(viewModel.store.segments.first?.id == firstVisible)
            try await context.manager.dbQueue.write { try SyncTransactionQueue.discard(vaultId: vaultId, in: $0) }
            #expect(await pollUntil { viewModel.meetingSyncState == .synced })
        }

        @Test
        func canonicalTranscriptRefreshInvalidatesDisplayedConversationMetrics() async throws {
            let context = try Self.makeContext()
            defer { try? FileManager.default.removeItem(at: context.vaultURL) }
            let connection = DahliaAccountConnectionRecord(id: .v7(), origin: "https://metrics.invalid", clientID: "test", createdAt: .now)
            let vaultId = try #require(try await context.manager.dbQueue.read { try MeetingRecord.fetchOne($0, key: context.meetingID)?.vaultId })
            try await context.manager.dbQueue.write { db in
                try connection.insert(db)
                try db.execute(
                    sql: "UPDATE vaults SET accountConnectionId = ?, syncConfirmedConnectionId = ? WHERE id = ?",
                    arguments: [connection.id, connection.id, vaultId]
                )
                try TranscriptContent(
                    id: .v7(),
                    meetingId: context.meetingID,
                    startTime: Date(),
                    text: "original",
                    isConfirmed: true,
                    audioSource: "mic"
                ).insert(db)
                try db.execute(sql: "INSERT INTO sync_entity_state VALUES (?, 'transcript', ?, 1)", arguments: [vaultId, context.meetingID])
                try db.execute(
                    sql: "INSERT INTO sync_content_state(vaultId, entity, entityId, residentRevision, complete) VALUES (?, 'transcript', ?, 1, 1)",
                    arguments: [vaultId, context.meetingID]
                )
            }
            let viewModel = CaptionViewModel()
            defer { viewModel.clearCurrentMeeting() }
            viewModel.loadMeeting(context.meetingID, dbQueue: context.manager.dbQueue, projectURL: nil, projectId: nil, vaultURL: nil)
            #expect(await pollUntil { viewModel.currentMeetingHasTranscriptSegments && !viewModel.store.isLoadingInitialPage })
            await viewModel.loadCurrentMeetingConversationMetrics()
            #expect(viewModel.conversationMetricsStore.metrics?.source(.microphone).segmentCount == 1)
            let reloadToken = viewModel.conversationMetricsStore.reloadToken
            try await context.manager.dbQueue.write { db in
                try db
                    .execute(
                        sql: """
                        INSERT INTO transcript_segment_bodies(segmentId, text)
                        SELECT id, 'canonical update'
                        FROM transcript_segments
                        WHERE true
                        ON CONFLICT(segmentId) DO UPDATE SET text = excluded.text
                        """
                    )
                try db.execute(sql: "UPDATE sync_entity_state SET confirmedRevision = 2 WHERE entity = 'transcript'")
                try db.execute(sql: "UPDATE sync_content_state SET residentRevision = 2 WHERE entity = 'transcript'")
            }
            #expect(await pollUntil { viewModel.conversationMetricsStore.reloadToken > reloadToken })
            #expect(viewModel.conversationMetricsStore.metrics == nil)
        }

        @Test
        func serverAdoptionClearsOpenTextAndSearchThenDisplaysRefetchedContent() async throws {
            let context = try Self.makeContext()
            defer { try? FileManager.default.removeItem(at: context.vaultURL) }
            let queue = context.manager.dbQueue
            let connection = DahliaAccountConnectionRecord(id: .v7(), origin: "https://discard.invalid", clientID: "test", createdAt: .now)
            let vaultId = try #require(try await queue.read { try MeetingRecord.fetchOne($0, key: context.meetingID)?.vaultId })
            let segmentId = UUID.v7()
            try await queue.write { db in
                try connection.insert(db)
                try db.execute(
                    sql: "UPDATE vaults SET accountConnectionId = ?, syncConfirmedConnectionId = ?, syncPullCursor = 'ready'",
                    arguments: [connection.id, connection.id]
                )
                try TranscriptContent(
                    id: segmentId,
                    meetingId: context.meetingID,
                    startTime: Date(),
                    text: "discarded transcript",
                    translatedText: "translation",
                    isConfirmed: true
                ).insert(db)
                try db.execute(sql: "INSERT INTO sync_entity_state VALUES (?, 'vault', ?, 1)", arguments: [vaultId, vaultId])
                for entity in ["summary", "transcript"] {
                    try db.execute(sql: "INSERT INTO sync_entity_state VALUES (?, ?, ?, 1)", arguments: [vaultId, entity, context.meetingID])
                    try db.execute(
                        sql: "INSERT INTO sync_content_state(vaultId, entity, entityId, residentRevision, complete) VALUES (?, ?, ?, 1, 1)",
                        arguments: [vaultId, entity, context.meetingID]
                    )
                }
            }
            let rejected = SummaryDocument(title: "Discarded summary", sections: [
                SummarySection(id: .v7(), heading: "Summary", blocks: [.paragraph("discardedneedle")]),
            ])
            try MeetingRepository(dbQueue: queue).applyGeneratedSummary(toMeetingId: context.meetingID, document: rejected, tags: [])
            try await queue.write { db in
                let patch = SyncOperationDraft(entity: .transcript, action: .patch, entityId: context.meetingID)
                let segment = try #require(try fetchTranscriptContent(id: segmentId, in: db))
                try SyncTransactionRecorder.record(
                    vaultId: vaultId,
                    operations: [patch],
                    transcriptSegments: [patch.id: [SyncTranscriptPatchSegment(segment)]],
                    in: db
                )
                try indexMeetingDocument(id: context.meetingID, generation: 1, in: db)
                #expect(try Int
                    .fetchOne(db, sql: "SELECT count(*) FROM search_documents_fts WHERE search_documents_fts MATCH 'discardedneedle'") == 1)
            }
            let viewModel = CaptionViewModel()
            defer { viewModel.clearCurrentMeeting() }
            viewModel.loadMeeting(context.meetingID, dbQueue: queue, projectURL: nil, projectId: nil, vaultURL: nil)
            #expect(await pollUntil {
                viewModel.currentSummaryDocument?.title == "Discarded summary" && viewModel.store.segments.count == 1 && !viewModel.store
                    .isLoadingInitialPage
            })
            viewModel.noteText = "Keep this note"
            let transaction = try #require(try await SyncTransactionQueue.claim(dbQueue: queue))
            try await SyncTransactionQueue.block(transaction, reason: .conflict, response: Data("{}".utf8), dbQueue: queue)
            try await SyncTransactionQueue.acceptServerVersion(vaultId: vaultId, dbQueue: queue)
            #expect(await pollUntil {
                viewModel.currentSummaryDocument == nil && viewModel.store.segments.isEmpty && viewModel.textContentState == .missing
            })
            try await queue.read { db throws in
                #expect(try Int
                    .fetchOne(db, sql: "SELECT count(*) FROM search_documents_fts WHERE search_documents_fts MATCH 'discardedneedle'") == 0)
                #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM summaries WHERE meetingId = ?", arguments: [context.meetingID]) == 1)
                #expect(try String
                    .fetchOne(db, sql: "SELECT translatedText FROM transcript_segments WHERE id = ?", arguments: [segmentId]) == "translation")
            }
            let canonical = try SummaryDocument(title: "Canonical summary", sections: []).databaseJSONString()
            try await queue.write { db in
                try db.execute(sql: "UPDATE summaries SET title = 'Canonical summary'")
                try SummaryBodyRecord(meetingId: context.meetingID, document: canonical).save(db)
                try db.execute(
                    sql: """
                    INSERT INTO transcript_segment_bodies(segmentId, text)
                    SELECT id, 'canonical transcript'
                    FROM transcript_segments
                    WHERE id = ?
                    ON CONFLICT(segmentId) DO UPDATE SET text = excluded.text
                    """,
                    arguments: [segmentId]
                )
                for entity in ["summary", "transcript"] {
                    try db.execute(sql: "INSERT INTO sync_entity_state VALUES (?, ?, ?, 2)", arguments: [vaultId, entity, context.meetingID])
                    try db.execute(sql: "UPDATE sync_content_state SET complete = 1, residentRevision = 2 WHERE entity = ?", arguments: [entity])
                }
            }
            #expect(await pollUntil {
                viewModel.currentSummaryDocument?.title == "Canonical summary" && viewModel.store.segments.first?.text == "canonical transcript"
            })
            #expect(viewModel.noteText == "Keep this note")
        }

        // MARK: - Helpers

        private struct Context {
            let manager: AppDatabaseManager
            let meetingID: UUID
            let vaultURL: URL

            func replaceSummary(title: String, body: String) throws {
                let document = try SummaryDocument(
                    title: title,
                    sections: [
                        SummarySection(id: .v7(), heading: "Summary", blocks: [.paragraph(body)]),
                    ]
                ).databaseJSONString()
                try manager.dbQueue.write { db in
                    try db.execute(
                        sql: "UPDATE summary_bodies SET document = ? WHERE meetingId = ?",
                        arguments: [document, meetingID]
                    )
                }
            }
        }

        private static func makeContext() throws -> Context {
            let manager = try AppDatabaseManager(path: ":memory:")
            let repo = MeetingRepository(dbQueue: manager.dbQueue)
            let vaultURL = URL.temporaryDirectory.appending(path: "dahlia-summary-reload-\(UUID.v7().uuidString)")
            try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)

            let vault = VaultRecord(
                id: .v7(),
                path: vaultURL.path,
                name: "Test Vault",
                createdAt: Date(),
                lastOpenedAt: Date()
            )
            try repo.insertVault(vault)
            let meeting = MeetingRecord(
                id: .v7(),
                vaultId: vault.id,
                projectId: nil,
                name: "Weekly sync",
                createdAt: Date(),
                updatedAt: Date()
            )
            let document = try SummaryDocument(
                title: "Original title",
                sections: [
                    SummarySection(id: .v7(), heading: "Summary", blocks: [.paragraph("Tanaka approved the plan")]),
                ]
            ).databaseJSONString()
            try manager.dbQueue.write { db in
                try meeting.insert(db)
                try SummaryContent(
                    meetingId: meeting.id,
                    title: "Original title",
                    document: document,
                    createdAt: Date()
                ).insert(db)
            }

            return Context(manager: manager, meetingID: meeting.id, vaultURL: vaultURL)
        }
    }
#endif
