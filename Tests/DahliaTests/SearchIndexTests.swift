import Foundation
import GRDB
@testable import Dahlia
@testable import DahliaRuntimeSupport

#if canImport(Testing)
    import Testing

    @MainActor
    // swiftlint:disable:next type_body_length
    struct SearchIndexTests {
        @Test
        func migrationCreatesProjectionWithoutSegmentQueue() throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let vault = Self.makeVault()
            let meeting = Self.makeMeeting(vaultID: vault.id)
            try database.dbQueue.write { db in
                try vault.insert(db)
                try meeting.insert(db)
                for index in 0 ..< 3 {
                    try Self.makeSegment(
                        meetingID: meeting.id,
                        text: "segment \(index)",
                        offset: TimeInterval(index)
                    ).insert(db)
                }
            }

            let snapshot = try database.dbQueue.read { db in
                try (
                    db.tableExists("search_documents"),
                    db.tableExists("search_documents_fts"),
                    Int.fetchOne(
                        db,
                        sql: """
                        SELECT COUNT(*) FROM search_index_jobs
                        WHERE indexKind = 'fts' AND targetKind = 'segment'
                        """
                    ) ?? 0,
                    String.fetchOne(
                        db,
                        sql: "SELECT sql FROM sqlite_master WHERE name = 'search_documents_fts'"
                    )
                )
            }

            #expect(snapshot.0)
            #expect(snapshot.1)
            #expect(snapshot.2 == 0)
            #expect(snapshot.3?.contains("detail=full") == true)
            #expect(snapshot.3?.contains("contentless_delete=1") == true)
            #expect(snapshot.3?.contains("summary") == true)
            #expect(snapshot.3?.contains("transcript") == false)
        }

        @Test
        func fullDetailPreservesBM25TermFrequency() throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let vault = Self.makeVault()
            try database.dbQueue.write { db in
                try vault.insert(db)
                for title in ["検索", "検索 検索 検索"] {
                    let id = UUID.v7()
                    try upsertDocument(
                        SearchDocumentProjection(
                            kind: "project",
                            sourceID: id,
                            vaultID: vault.id,
                            meetingID: nil,
                            projectID: id,
                            fields: SearchDocumentFields(
                                title: title,
                                description: "",
                                calendar: "",
                                tags: "",
                                projectPath: ""
                            )
                        ),
                        generation: 1,
                        in: db
                    )
                }
                let scores = try Double.fetchAll(
                    db,
                    sql: "SELECT bm25(search_documents_fts) FROM search_documents_fts WHERE search_documents_fts MATCH '検索'"
                )
                #expect(Set(scores).count == 2)
            }
        }

        @Test
        func transcriptSegmentsAreNotIndexedOrSearched() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let vault = Self.makeVault()
            let meeting = Self.makeMeeting(vaultID: vault.id)
            try await database.dbQueue.write { db in
                try vault.insert(db)
                try meeting.insert(db)
                try Self.makeSegment(meetingID: meeting.id, text: "検索について話します", offset: 10).insert(db)
                try Self.makeSegment(meetingID: meeting.id, text: "精度を改善します", offset: 20).insert(db)
                try Self.makeSegment(
                    meetingID: meeting.id,
                    text: "未確定だけの秘密語",
                    offset: 30,
                    isConfirmed: false
                ).insert(db)
            }

            await database.searchIndexer.drain()
            let page = try await MeetingRepository.searchMeetingSidebarPage(
                vaultId: vault.id,
                query: "検索精度",
                limit: 20,
                dbQueue: database.dbQueue
            )
            let segmentDocumentCount = try await database.dbQueue.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM search_documents WHERE kind = 'segment'") ?? -1
            }

            #expect(page.items.isEmpty)
            #expect(segmentDocumentCount == 0)
        }

        @Test
        func summaryBodyIsIndexedUpdatedDeletedAndAvailableToSimpleSearch() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let vault = Self.makeVault()
            let meeting = Self.makeMeeting(vaultID: vault.id)
            try await database.dbQueue.write { db in
                try vault.insert(db)
                try meeting.insert(db)
                try SummaryRecord(
                    meetingId: meeting.id,
                    title: "Excluded summary title",
                    document: try Self.summaryDocument(body: "要約固有語を記録").databaseJSONString(),
                    createdAt: .now
                ).insert(db)
            }
            await database.searchIndexer.drain()

            let advanced = try await MeetingRepository.searchMeetingSidebarPage(
                vaultId: vault.id,
                query: "要約固有語",
                limit: 20,
                dbQueue: database.dbQueue
            )
            let simple = try await MeetingRepository.searchMeetingSidebarPage(
                vaultId: vault.id,
                query: "約固有",
                mode: .simple,
                limit: 20,
                dbQueue: database.dbQueue
            )
            #expect(advanced.items.map(\.id) == [meeting.id])
            #expect(advanced.items.first?.searchMatchContext?.kind == .summary)
            #expect(simple.items.map(\.id) == [meeting.id])
            #expect(simple.items.first?.searchMatchContext?.kind == .summary)

            try await database.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE summaries SET document = ? WHERE meetingId = ?",
                    arguments: [try Self.summaryDocument(body: "更新後要約語を記録").databaseJSONString(), meeting.id]
                )
            }
            await database.searchIndexer.drain()
            let oldResult = try await MeetingRepository.searchMeetingSidebarPage(
                vaultId: vault.id,
                query: "要約固有語",
                limit: 20,
                dbQueue: database.dbQueue
            )
            let updatedResult = try await MeetingRepository.searchMeetingSidebarPage(
                vaultId: vault.id,
                query: "更新後要約語",
                limit: 20,
                dbQueue: database.dbQueue
            )
            #expect(oldResult.items.isEmpty)
            #expect(updatedResult.items.map(\.id) == [meeting.id])

            try await database.dbQueue.write { db in
                _ = try SummaryRecord.deleteOne(db, key: meeting.id)
            }
            await database.searchIndexer.drain()
            let deletedResult = try await MeetingRepository.searchMeetingSidebarPage(
                vaultId: vault.id,
                query: "更新後要約語",
                limit: 20,
                dbQueue: database.dbQueue
            )
            #expect(deletedResult.items.isEmpty)
        }

        @Test
        func invalidSummaryDocumentDoesNotFailMetadataIndexing() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let vault = Self.makeVault()
            let meeting = {
                var value = Self.makeMeeting(vaultID: vault.id)
                value.name = "壊れても検索可能"
                return value
            }()
            try await database.dbQueue.write { db in
                try vault.insert(db)
                try meeting.insert(db)
                try SummaryRecord(meetingId: meeting.id, title: "Invalid", document: "{}", createdAt: .now).insert(db)
            }

            await database.searchIndexer.drain()

            let phase = try await database.dbQueue.read { db in
                try String.fetchOne(db, sql: "SELECT phase FROM search_index_state WHERE indexKind = 'fts'")
            }
            let result = try await MeetingRepository.searchMeetingSidebarPage(
                vaultId: vault.id,
                query: "検索可能",
                limit: 20,
                dbQueue: database.dbQueue
            )
            #expect(phase == "ready")
            #expect(result.items.map(\.id) == [meeting.id])
        }

        @Test
        func rareTermNarrowsACommonTermBeforeTheSearchDeadline() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let vault = Self.makeVault()
            let targetID = UUID.v7()
            try await database.dbQueue.write { db in
                try vault.insert(db)
                for index in 0 ... 2000 {
                    var meeting = Self.makeMeeting(vaultID: vault.id)
                    meeting.id = index == 0 ? targetID : .v7()
                    meeting.name = index == 0 ? "会議 固有顧客名" : "会議"
                    try meeting.insert(db)
                    try upsertDocument(
                        SearchDocumentProjection(
                            kind: "meeting",
                            sourceID: meeting.id,
                            vaultID: vault.id,
                            meetingID: meeting.id,
                            projectID: nil,
                            fields: SearchDocumentFields(
                                title: meeting.name,
                                description: "",
                                calendar: "",
                                tags: "",
                                projectPath: ""
                            )
                        ),
                        generation: 1,
                        in: db
                    )
                }
                try db.execute(sql: "DELETE FROM search_index_jobs")
                try db.execute(sql: "UPDATE search_index_state SET phase = 'ready' WHERE indexKind = 'fts'")
            }

            let page = try await MeetingRepository.searchMeetingSidebarPage(
                vaultId: vault.id,
                query: "会議 固有顧客名",
                limit: 20,
                dbQueue: database.dbQueue
            )

            #expect(page.items.map(\.id) == [targetID])
        }

        @Test
        func projectSearchBoundsCommonMatchesAndRetainsTheRareResult() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let vault = Self.makeVault()
            let targetID = UUID.v7()
            try await database.dbQueue.write { db in
                try vault.insert(db)
                for index in 0 ... 2000 {
                    let projectID = index == 0 ? targetID : UUID.v7()
                    let title = index == 0 ? "会議 固有顧客名" : "会議"
                    try upsertDocument(
                        SearchDocumentProjection(
                            kind: "project",
                            sourceID: projectID,
                            vaultID: vault.id,
                            meetingID: nil,
                            projectID: projectID,
                            fields: SearchDocumentFields(
                                title: title,
                                description: "",
                                calendar: "",
                                tags: "",
                                projectPath: title
                            )
                        ),
                        generation: 1,
                        in: db
                    )
                }
                try db.execute(sql: "DELETE FROM search_index_jobs")
                try db.execute(sql: "UPDATE search_index_state SET phase = 'ready' WHERE indexKind = 'fts'")
            }

            let common = try await MeetingRepository.searchProjectIDs(
                vaultID: vault.id,
                query: "会議",
                limit: 20,
                dbQueue: database.dbQueue
            )
            let narrowed = try await MeetingRepository.searchProjectIDs(
                vaultID: vault.id,
                query: "会議 固有顧客名",
                limit: 20,
                dbQueue: database.dbQueue
            )

            #expect(common.count == 20)
            #expect(narrowed == [targetID])
        }

        @Test
        func deletingMeetingRemovesItsRegistryAndFTSRows() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let vault = Self.makeVault()
            let meeting = Self.makeMeeting(vaultID: vault.id)
            try await database.dbQueue.write { db in
                try vault.insert(db)
                try meeting.insert(db)
                try Self.makeSegment(meetingID: meeting.id, text: "削除対象の本文", offset: 10).insert(db)
            }
            await database.searchIndexer.drain()

            try await database.dbQueue.write { db in
                _ = try MeetingRecord.deleteOne(db, key: meeting.id)
            }
            await database.searchIndexer.drain()

            let counts = try await database.dbQueue.read { db in
                try (
                    Int.fetchOne(
                        db,
                        sql: "SELECT COUNT(*) FROM search_documents WHERE meetingId = ?",
                        arguments: [meeting.id]
                    ) ?? -1,
                    Int.fetchOne(db, sql: "SELECT COUNT(*) FROM search_documents_fts") ?? -1
                )
            }
            #expect(counts.0 == 0)
            #expect(counts.1 == 0)
        }

        @Test
        func failedIndexStillDrainsDeletionJobs() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let vault = Self.makeVault()
            let meeting = Self.makeMeeting(vaultID: vault.id)
            try await database.dbQueue.write { db in
                try vault.insert(db)
                try meeting.insert(db)
                try Self.makeSegment(meetingID: meeting.id, text: "失敗後に消す本文", offset: 10).insert(db)
            }
            await database.searchIndexer.drain()

            try await database.dbQueue.write { db in
                try db.execute(sql: "UPDATE search_index_state SET phase = 'failed' WHERE indexKind = 'fts'")
                _ = try MeetingRecord.deleteOne(db, key: meeting.id)
            }
            await database.searchIndexer.drain()

            let snapshot = try await database.dbQueue.read { db in
                try (
                    String.fetchOne(db, sql: "SELECT phase FROM search_index_state WHERE indexKind = 'fts'"),
                    Int.fetchOne(
                        db,
                        sql: "SELECT COUNT(*) FROM search_documents WHERE meetingId = ?",
                        arguments: [meeting.id]
                    ) ?? -1,
                    Int.fetchOne(db, sql: "SELECT COUNT(*) FROM search_documents_fts") ?? -1
                )
            }
            #expect(snapshot.0 == "failed")
            #expect(snapshot.1 == 0)
            #expect(snapshot.2 == 0)
        }

        @Test
        func deletingVaultRemovesEveryProjectedDocument() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let vault = Self.makeVault()
            let project = ProjectRecord(
                id: .v7(),
                vaultId: vault.id,
                path: "削除対象プロジェクト",
                createdAt: .now
            )
            var configuredMeeting = Self.makeMeeting(vaultID: vault.id)
            configuredMeeting.projectId = project.id
            let meeting = configuredMeeting
            let segment = Self.makeSegment(meetingID: meeting.id, text: "削除対象の発話", offset: 10)
            try await database.dbQueue.write { db in
                try vault.insert(db)
                try project.insert(db)
                try meeting.insert(db)
                try segment.insert(db)
            }
            await database.searchIndexer.drain()

            try await database.dbQueue.write { db in
                _ = try VaultRecord.deleteOne(db, key: vault.id)
            }
            await database.searchIndexer.drain()

            let counts = try await database.dbQueue.read { db in
                try (
                    Int.fetchOne(db, sql: "SELECT COUNT(*) FROM search_documents") ?? -1,
                    Int.fetchOne(db, sql: "SELECT COUNT(*) FROM search_documents_fts") ?? -1
                )
            }
            #expect(counts.0 == 0)
            #expect(counts.1 == 0)
        }

        @Test
        func missingFTSRowTriggersARepairingRebuild() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let vault = Self.makeVault()
            let meeting = Self.makeMeeting(vaultID: vault.id)
            try await database.dbQueue.write { db in
                try vault.insert(db)
                try meeting.insert(db)
            }
            await database.searchIndexer.drain()

            try await database.dbQueue.write { db in
                let fetchedRowID = try Int64.fetchOne(
                    db,
                    sql: "SELECT id FROM search_documents WHERE kind = 'meeting' AND sourceId = ?",
                    arguments: [meeting.id]
                )
                let rowID = try #require(fetchedRowID)
                try db.execute(sql: "DELETE FROM search_documents_fts WHERE rowid = ?", arguments: [rowID])
            }
            await database.searchIndexer.drain()

            let result = try await MeetingRepository.searchMeetingSidebarPage(
                vaultId: vault.id,
                query: "検索会議",
                limit: 20,
                dbQueue: database.dbQueue
            )
            #expect(result.items.map(\.id) == [meeting.id])
        }

        @Test
        func sourceMutationInvalidatesRelevanceCursorBeforeIndexingCompletes() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let vault = Self.makeVault()
            let first = Self.makeMeeting(vaultID: vault.id)
            let second = Self.makeMeeting(vaultID: vault.id)
            try await database.dbQueue.write { db in
                try vault.insert(db)
                try first.insert(db)
                try second.insert(db)
            }
            await database.searchIndexer.drain()

            let firstPage = try await MeetingRepository.searchMeetingSidebarPage(
                vaultId: vault.id,
                query: "検索会議",
                limit: 1,
                dbQueue: database.dbQueue
            )
            let cursor = try #require(firstPage.nextCursor)
            let removedID = try #require(firstPage.items.first?.id)
            try await database.dbQueue.write { db in
                _ = try MeetingRecord.deleteOne(db, key: removedID)
            }

            let refreshedPage = try await MeetingRepository.searchMeetingSidebarPage(
                vaultId: vault.id,
                query: "検索会議",
                after: cursor,
                limit: 1,
                dbQueue: database.dbQueue
            )
            #expect(refreshedPage.replacesResults)
            #expect(refreshedPage.items.count == 1)
            #expect(refreshedPage.items.first?.id != removedID)
        }

        @Test
        func explicitRebuildRetokenizesRowsWithUnchangedSourceHashes() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let vault = Self.makeVault()
            let meeting = Self.makeMeeting(vaultID: vault.id)
            try await database.dbQueue.write { db in
                try vault.insert(db)
                try meeting.insert(db)
            }
            await database.searchIndexer.drain()

            try await database.dbQueue.write { db in
                let fetchedRowID = try Int64.fetchOne(
                    db,
                    sql: "SELECT id FROM search_documents WHERE kind = 'meeting' AND sourceId = ?",
                    arguments: [meeting.id]
                )
                let rowID = try #require(fetchedRowID)
                try db.execute(
                    sql: """
                    UPDATE search_documents_fts
                    SET title = '破損内容', description = '', summary = '', calendar = '', tags = '', projectPath = ''
                    WHERE rowid = ?
                    """,
                    arguments: [rowID]
                )
            }

            try await database.searchIndexer.requestRebuild()
            let result = try await MeetingRepository.searchMeetingSidebarPage(
                vaultId: vault.id,
                query: "検索会議",
                limit: 20,
                dbQueue: database.dbQueue
            )
            #expect(result.items.map(\.id) == [meeting.id])
        }

        @Test
        func failedIndexWaitsForAnExplicitRebuildRequest() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let vault = Self.makeVault()
            let meeting = Self.makeMeeting(vaultID: vault.id)
            try await database.dbQueue.write { db in
                try vault.insert(db)
                try meeting.insert(db)
                try db.execute(
                    sql: "UPDATE search_index_state SET phase = 'failed' WHERE indexKind = 'fts'"
                )
            }

            await database.searchIndexer.drain()
            let paused = try await database.dbQueue.read { db in
                try (
                    Int.fetchOne(db, sql: "SELECT COUNT(*) FROM search_documents") ?? -1,
                    Int.fetchOne(db, sql: "SELECT COUNT(*) FROM search_index_jobs") ?? -1
                )
            }
            #expect(paused.0 == 0)
            #expect(paused.1 > 0)

            try await database.searchIndexer.requestRebuild()
            let resumed = try await database.dbQueue.read { db in
                try (
                    String.fetchOne(db, sql: "SELECT phase FROM search_index_state WHERE indexKind = 'fts'"),
                    Int.fetchOne(db, sql: "SELECT COUNT(*) FROM search_index_jobs") ?? -1
                )
            }
            #expect(resumed.0 == "ready")
            #expect(resumed.1 == 0)
        }

        @Test
        func permanentlyInvalidJobStopsAfterFiveAttempts() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let targetID = UUID.v7()
            try await database.dbQueue.write { db in
                try db.execute(sql: "UPDATE search_index_state SET phase = 'ready' WHERE indexKind = 'fts'")
                try db.execute(
                    sql: """
                    INSERT INTO search_index_jobs(
                        indexKind, targetKind, targetKey, availableAt, updatedAt
                    ) VALUES('fts', 'invalid', ?, ?, ?)
                    """,
                    arguments: [targetID, Date(), Date()]
                )
            }

            for _ in 0 ..< 4 {
                await database.searchIndexer.drain()
                try await database.dbQueue.write { db in
                    try db.execute(
                        sql: "UPDATE search_index_jobs SET availableAt = ? WHERE targetKey = ?",
                        arguments: [Date.distantPast, targetID]
                    )
                }
            }
            let attempts = try await database.dbQueue.read { db in
                try Int.fetchOne(db, sql: "SELECT attempts FROM search_index_jobs WHERE targetKey = ?", arguments: [targetID])
            }
            #expect(attempts == 4)
            await database.searchIndexer.drain()

            let result = try await database.dbQueue.read { db in
                try (
                    Int.fetchOne(db, sql: "SELECT COUNT(*) FROM search_index_jobs WHERE targetKey = ?", arguments: [targetID]),
                    String.fetchOne(db, sql: "SELECT phase FROM search_index_state WHERE indexKind = 'fts'")
                )
            }
            #expect(result.0 == 0)
            #expect(result.1 == "failed")
        }

        @Test
        func transcriptIsNotIndexedOrRequeued() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let vault = Self.makeVault()
            let meeting = Self.makeMeeting(vaultID: vault.id)
            let segment = Self.makeSegment(
                meetingID: meeting.id,
                text: "原文だけの検索語",
                translatedText: "翻訳された品質保証",
                offset: 10
            )
            try await database.dbQueue.write { db in
                try vault.insert(db)
                try meeting.insert(db)
                try segment.insert(db)
            }
            await database.searchIndexer.drain()

            let result = try await MeetingRepository.searchMeetingSidebarPage(
                vaultId: vault.id,
                query: "品質保証",
                limit: 20,
                dbQueue: database.dbQueue
            )
            #expect(result.items.isEmpty)

            let original = try await MeetingRepository.searchMeetingSidebarPage(
                vaultId: vault.id,
                query: "原文検索語",
                limit: 20,
                dbQueue: database.dbQueue
            )
            #expect(original.items.isEmpty)

            try await database.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE transcript_segments SET translatedText = ? WHERE meetingId = ?",
                    arguments: ["更新後の翻訳", meeting.id]
                )
            }
            let queued = try await database.dbQueue.read { db in
                try Int.fetchOne(
                    db,
                    sql: """
                    SELECT COUNT(*) FROM search_index_jobs
                    WHERE indexKind = 'fts' AND targetKind = 'segment' AND targetKey = ?
                    """,
                    arguments: [segment.id]
                ) ?? -1
            }
            #expect(queued == 0)
        }

        @Test
        func calendarUpdateQueuesOnlyReferencingMeetings() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let vault = Self.makeVault()
            let event = Self.makeCalendarEvent()
            let linkedMeeting = {
                var meeting = Self.makeMeeting(vaultID: vault.id)
                meeting.calendarEventIcalUid = event.icalUid
                meeting.calendarEventRecurrenceId = event.recurrenceId
                return meeting
            }()
            let unrelatedMeeting = Self.makeMeeting(vaultID: vault.id)
            try await database.dbQueue.write { db in
                try vault.insert(db)
                try CalendarEventRecord.upsert(event: event, now: .now, in: db)
                try linkedMeeting.insert(db)
                try unrelatedMeeting.insert(db)
            }
            await database.searchIndexer.drain()

            try await database.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE calendar_events SET title = ? WHERE ical_uid = ? AND recurrence_id = ?",
                    arguments: ["更新された予定", event.icalUid, event.recurrenceId]
                )
            }

            let queuedMeetingIDs = try await database.dbQueue.read { db in
                try UUID.fetchAll(
                    db,
                    sql: "SELECT targetKey FROM search_index_jobs WHERE indexKind = 'fts' AND targetKind = 'meeting'"
                )
            }
            #expect(queuedMeetingIDs == [linkedMeeting.id])
        }

        @Test
        func projectUpdatesQueueOnlyTheChangedContentOrHierarchy() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let vault = Self.makeVault()
            let firstRoot = ProjectRecord(
                id: .v7(),
                vaultId: vault.id,
                parentProjectId: nil,
                name: "First",
                createdAt: .now,
                projectType: .internal
            )
            let child = ProjectRecord(
                id: .v7(),
                vaultId: vault.id,
                parentProjectId: firstRoot.id,
                name: "Child",
                createdAt: .now,
                projectType: nil
            )
            let unrelated = ProjectRecord(
                id: .v7(),
                vaultId: vault.id,
                parentProjectId: nil,
                name: "Unrelated",
                createdAt: .now,
                projectType: .internal
            )
            try await database.dbQueue.write { db in
                try vault.insert(db)
                try firstRoot.insert(db)
                try child.insert(db)
                try unrelated.insert(db)
            }
            await database.searchIndexer.drain()

            try await database.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE projects SET description = ? WHERE id = ?",
                    arguments: ["Changed", child.id]
                )
            }
            let contentJobs = try database.dbQueue.read { db in
                try Row.fetchAll(db, sql: "SELECT targetKind, targetKey FROM search_index_jobs")
            }
            #expect(contentJobs.count == 1)
            #expect(contentJobs.first?["targetKind"] as String? == "project")
            #expect(contentJobs.first?["targetKey"] as UUID? == child.id)
            await database.searchIndexer.drain()

            let unrelatedUpdatedAt = try await database.dbQueue.read { db in
                try Date.fetchOne(
                    db,
                    sql: "SELECT updatedAt FROM search_documents WHERE kind = 'project' AND sourceId = ?",
                    arguments: [unrelated.id]
                )
            }
            try await database.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE projects SET name = ? WHERE id = ?",
                    arguments: ["Renamed", firstRoot.id]
                )
            }
            let hierarchyJobs = try database.dbQueue.read { db in
                try Row.fetchAll(db, sql: "SELECT targetKind, targetKey FROM search_index_jobs")
            }
            #expect(hierarchyJobs.count == 1)
            #expect(hierarchyJobs.first?["targetKind"] as String? == "projectHierarchy")
            #expect(hierarchyJobs.first?["targetKey"] as UUID? == firstRoot.id)
            await database.searchIndexer.drain()

            let unrelatedUpdatedAfterHierarchyChange = try await database.dbQueue.read { db in
                try Date.fetchOne(
                    db,
                    sql: "SELECT updatedAt FROM search_documents WHERE kind = 'project' AND sourceId = ?",
                    arguments: [unrelated.id]
                )
            }
            let projectIDs = try await MeetingRepository.searchProjectIDs(
                vaultID: vault.id,
                query: "Renamed Child",
                limit: 20,
                dbQueue: database.dbQueue
            )
            #expect(unrelatedUpdatedAfterHierarchyChange == unrelatedUpdatedAt)
            #expect(projectIDs == [child.id])
        }

        @Test
        func migrationFromV34PreservesExistingSearchSources() throws {
            let queue = try DatabaseQueue()
            try AppDatabaseManager.migrator.migrate(queue, upTo: "v34_meetingRecordingStartedAt")
            let vault = Self.makeVault()
            let project = ProjectRecord(
                id: .v7(),
                vaultId: vault.id,
                path: "既存プロジェクト",
                createdAt: .now,
                description: "移行前の説明"
            )
            var meeting = Self.makeMeeting(vaultID: vault.id)
            meeting.projectId = project.id
            let segment = Self.makeSegment(meetingID: meeting.id, text: "移行前の文字起こし", offset: 10)
            try queue.write { db in
                try vault.insert(db)
                try project.insert(db)
                try meeting.insert(db)
                try segment.insert(db)
            }

            try AppDatabaseManager.migrator.migrate(queue)

            let snapshot = try queue.read { db in
                try (
                    ProjectRecord.fetchOne(db, key: project.id),
                    MeetingRecord.fetchOne(db, key: meeting.id),
                    TranscriptSegmentRecord.fetchOne(db, key: segment.id),
                    String.fetchOne(db, sql: "SELECT phase FROM search_index_state WHERE indexKind = 'fts'"),
                    Int.fetchOne(db, sql: "SELECT COUNT(*) FROM search_documents") ?? -1
                )
            }
            #expect(snapshot.0?.description == "移行前の説明")
            #expect(snapshot.1?.projectId == project.id)
            #expect(snapshot.2?.text == "移行前の文字起こし")
            #expect(snapshot.3 == "pending")
            #expect(snapshot.4 == 0)
        }

        @Test
        func migrationFromV35PreservesSourcesAndRebuildsSummaryIndex() async throws {
            let queue = try DatabaseQueue()
            try AppDatabaseManager.migrator.migrate(queue, upTo: "v35_searchDocuments")
            let vault = Self.makeVault()
            let meeting = Self.makeMeeting(vaultID: vault.id)
            try await queue.write { db in
                try vault.insert(db)
                try meeting.insert(db)
                try SummaryRecord(
                    meetingId: meeting.id,
                    title: "Preserved",
                    document: try Self.summaryDocument(body: "移行後検索対象").databaseJSONString(),
                    createdAt: .now
                ).insert(db)
                try db.execute(
                    sql: """
                    INSERT INTO search_documents(
                        kind, sourceId, vaultId, meetingId, projectId,
                        sourceContentHash, indexGeneration, updatedAt
                    ) VALUES('meeting', ?, ?, ?, NULL, 'v35-hash', 1, ?)
                    """,
                    arguments: [meeting.id, vault.id, meeting.id, Date.now]
                )
                try db.execute(
                    sql: """
                    INSERT INTO search_documents_fts(rowid, title, description, calendar, tags, projectPath)
                    VALUES(?, ?, '', '', '', '')
                    """,
                    arguments: [db.lastInsertedRowID, meeting.name]
                )
                try db.execute(sql: "UPDATE search_index_state SET phase = 'ready' WHERE indexKind = 'fts'")
            }

            try AppDatabaseManager.migrator.migrate(queue)

            let migrated = try await queue.read { db in
                try (
                    MeetingRecord.fetchOne(db, key: meeting.id),
                    SummaryRecord.fetchOne(db, key: meeting.id),
                    Set(String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('search_documents_fts')")),
                    String.fetchOne(db, sql: "SELECT phase FROM search_index_state WHERE indexKind = 'fts'"),
                    Int.fetchOne(db, sql: "SELECT COUNT(*) FROM search_documents_fts") ?? -1
                )
            }
            #expect(migrated.0?.id == meeting.id)
            #expect(migrated.1?.title == "Preserved")
            #expect(migrated.2.contains("summary"))
            #expect(migrated.3 == "pending")
            #expect(migrated.4 == 0)

            let indexer = SearchIndexer(dbQueue: queue)
            await indexer.drain()
            let result = try await MeetingRepository.searchMeetingSidebarPage(
                vaultId: vault.id,
                query: "移行後検索対象",
                limit: 20,
                dbQueue: queue
            )
            #expect(result.items.map(\.id) == [meeting.id])
        }

        @Test
        func summarySearchMigrationCanBeRerun() throws {
            let database = try AppDatabaseManager(path: ":memory:")

            try database.dbQueue.write { db in
                try SummarySearchMigration.migrate(in: db)
            }

            let triggerCount = try database.dbQueue.read { db in
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger' AND name LIKE 'search_queue_summaries_%'"
                ) ?? 0
            }
            #expect(triggerCount == 3)
        }

        @Test
        func schemaSignatureIncludesFTSShadowTables() throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let matches = try database.dbQueue.read { db in
                try AppDatabaseManager.hasExpectedCurrentSchema(db)
            }
            let shadows = try database.dbQueue.read { db in
                try String.fetchAll(
                    db,
                    sql: "SELECT name FROM sqlite_master WHERE name LIKE 'search_documents_fts_%' ORDER BY name"
                )
            }
            #expect(matches)
            #expect(shadows.contains("search_documents_fts_config"))
            #expect(shadows.contains("search_documents_fts_data"))
        }

        private nonisolated static func makeVault() -> VaultRecord {
            VaultRecord(
                id: .v7(),
                path: "/tmp/search-index-vault",
                name: "Search",
                createdAt: .now,
                lastOpenedAt: .now
            )
        }

        private nonisolated static func summaryDocument(body: String) -> SummaryDocument {
            SummaryDocument(
                title: "Excluded title",
                description: "Excluded description",
                sections: [SummarySection(id: .v7(), heading: "", blocks: [.paragraph(body)])],
                tags: ["Excluded tag"],
                actionItems: [.init(title: "Excluded action", assignee: "Excluded assignee")]
            )
        }

        private nonisolated static func makeMeeting(vaultID: UUID) -> MeetingRecord {
            MeetingRecord(
                id: .v7(),
                vaultId: vaultID,
                projectId: nil,
                name: "検索会議",
                createdAt: .now,
                updatedAt: .now
            )
        }

        private nonisolated static func makeSegment(
            meetingID: UUID,
            text: String,
            translatedText: String? = nil,
            offset: TimeInterval,
            isConfirmed: Bool = true
        ) -> TranscriptSegmentRecord {
            let start = Date(timeIntervalSince1970: 1_800_000_000 + offset)
            return TranscriptSegmentRecord(
                id: .v7(),
                meetingId: meetingID,
                startTime: start,
                endTime: start.addingTimeInterval(5),
                text: text,
                translatedText: translatedText,
                isConfirmed: isConfirmed
            )
        }

        private nonisolated static func makeCalendarEvent() -> CalendarEvent {
            let start = Date(timeIntervalSince1970: 1_800_000_000)
            return CalendarEvent(
                id: "search-index-event",
                calendarID: "primary",
                calendarName: "Primary",
                calendarColorHex: nil,
                platformId: "search-index-event",
                title: "検索予定",
                description: "",
                icalUid: "search-index@example.com",
                startDate: start,
                endDate: start.addingTimeInterval(3600),
                isAllDay: false,
                conferenceURI: nil
            )
        }
    }
#endif
