import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct HybridSearchQualityTests {
        @Test
        func hybridSearchRejectsLowSimilarityAndPrefersFTSOnTie() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let vault = makeVault(name: "Primary")
            let exact = makeMeeting(vaultID: vault.id, name: "Needle exact", description: body("exact"))
            let semantic = makeMeeting(vaultID: vault.id, name: "Semantic", description: body("semantic"))
            let weak = makeMeeting(vaultID: vault.id, name: "Weak", description: body("weak"))
            try await database.dbQueue.write { db in
                try vault.insert(db)
                try exact.insert(db)
                try semantic.insert(db)
                try weak.insert(db)
            }
            await database.searchIndexer.drain()
            try await installVectors(
                [(semantic.id, 0.80), (weak.id, HybridSearchRRF.minimumVectorSimilarity - 0.01)],
                in: database
            )

            let page = try await MeetingRepository.searchMeetingSidebarPage(
                vaultId: vault.id,
                query: "Needle",
                mode: .neural,
                queryEmbedding: unitVector(similarity: 1),
                limit: 10,
                dbQueue: database.dbQueue
            )

            #expect(page.items.map(\.id) == [exact.id, semantic.id])
            #expect(page.items.map(\.isSemanticHit) == [false, true])
            #expect(page.items.first?.searchMatchContext?.kind == .title)
            #expect(page.items.last?.searchMatchContext?.kind == .semantic)

            try await database.dbQueue.write { db in
                try db.execute(
                    sql: """
                    UPDATE search_index_state SET analyzerConfigurationHash = 'stale'
                    WHERE indexKind = 'vector'
                    """
                )
            }
            let observation = try await database.dbQueue.read {
                try SidebarViewModel.searchIndexObservationValues(in: $0)
            }
            let fallback = try await MeetingRepository.searchMeetingSidebarPage(
                vaultId: vault.id,
                query: "Needle",
                mode: .neural,
                queryEmbedding: unitVector(similarity: 1),
                limit: 10,
                dbQueue: database.dbQueue
            )
            let settings = SearchSettingsModel(database: database)
            await settings.refresh()
            #expect(observation[2] == 0)
            #expect(settings.vectorPhase == "pending")
            #expect(settings.vectorCompletedCount == 0)
            #expect(fallback.items.map(\.id) == [exact.id])
        }

        @Test
        func projectSimilarityReranksButDoesNotCreateMeetingCandidates() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let vault = makeVault(name: "Project rerank")
            let strongProject = makeProject(vaultID: vault.id, name: "Strong context")
            let weakProject = makeProject(vaultID: vault.id, name: "Weak context")
            let boosted = makeMeeting(vaultID: vault.id, projectID: strongProject.id, name: "Boosted")
            let unboosted = makeMeeting(vaultID: vault.id, projectID: weakProject.id, name: "Unboosted")
            let belowThreshold = makeMeeting(vaultID: vault.id, projectID: strongProject.id, name: "Below threshold")
            try await database.dbQueue.write { db in
                try vault.insert(db)
                try strongProject.insert(db)
                try weakProject.insert(db)
                try boosted.insert(db)
                try unboosted.insert(db)
                try belowThreshold.insert(db)
            }
            await database.searchIndexer.drain()
            try await installVectors(
                [
                    (boosted.id, 0.65),
                    (unboosted.id, 0.70),
                    (belowThreshold.id, HybridSearchRRF.minimumVectorSimilarity - 0.01),
                ],
                in: database
            )
            try await installProjectVectors(
                [(strongProject.id, 1), (weakProject.id, 0.20)],
                in: database
            )

            let page = try await MeetingRepository.searchMeetingSidebarPage(
                vaultId: vault.id,
                query: "context-rerank-query",
                mode: .neural,
                queryEmbedding: unitVector(similarity: 1),
                limit: 10,
                dbQueue: database.dbQueue
            )

            #expect(page.items.map(\.id) == [boosted.id, unboosted.id])
            #expect(!page.items.contains { $0.id == belowThreshold.id })
        }

        @Test
        func hybridSearchAppliesVaultProjectTagAndDateFiltersBeforeFusion() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let primary = makeVault(name: "Primary")
            let otherVault = makeVault(name: "Other")
            let parent = makeProject(vaultID: primary.id, name: "Parent")
            let child = makeProject(vaultID: primary.id, parentID: parent.id, name: "Child")
            let sibling = makeProject(vaultID: primary.id, name: "Sibling")
            let foreignProject = makeProject(vaultID: otherVault.id, name: "Foreign")
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let target = makeMeeting(vaultID: primary.id, projectID: child.id, name: "Target", date: now)
            let wrongTag = makeMeeting(vaultID: primary.id, projectID: child.id, name: "Wrong tag", date: now)
            let wrongProject = makeMeeting(vaultID: primary.id, projectID: sibling.id, name: "Wrong project", date: now)
            let wrongDate = makeMeeting(vaultID: primary.id, projectID: child.id, name: "Wrong date", date: .distantPast)
            let wrongVault = makeMeeting(vaultID: otherVault.id, projectID: foreignProject.id, name: "Wrong vault", date: now)
            let tagID = try await database.dbQueue.write { db in
                try primary.insert(db)
                try otherVault.insert(db)
                try parent.insert(db)
                try child.insert(db)
                try sibling.insert(db)
                try foreignProject.insert(db)
                try target.insert(db)
                try wrongTag.insert(db)
                try wrongProject.insert(db)
                try wrongDate.insert(db)
                try wrongVault.insert(db)
                let tag = TagRecord(id: nil, name: "Important", colorHex: "#FF0000", createdAt: .now)
                try tag.insert(db)
                let tagID = db.lastInsertedRowID
                for meetingID in [target.id, wrongProject.id, wrongDate.id, wrongVault.id] {
                    try db.execute(
                        sql: "INSERT INTO meeting_tags(meetingId, tagId) VALUES(?, ?)",
                        arguments: [meetingID, tagID]
                    )
                }
                return tagID
            }
            await database.searchIndexer.drain()
            try await installVectors(
                [target.id, wrongTag.id, wrongProject.id, wrongDate.id, wrongVault.id]
                    .enumerated().map { ($1, 0.90 - Float($0) * 0.02) },
                in: database
            )

            let page = try await MeetingRepository.searchMeetingSidebarPage(
                vaultId: primary.id,
                criteria: MeetingSearchCriteria(
                    text: "semantic-only-query",
                    projectIDs: [parent.id],
                    tagIDs: [tagID],
                    startDate: now.addingTimeInterval(-60),
                    endDate: now.addingTimeInterval(60)
                ),
                mode: .neural,
                queryEmbedding: unitVector(similarity: 1),
                limit: 10,
                dbQueue: database.dbQueue
            )
            #expect(page.items.map(\.id) == [target.id])
            #expect(page.items.first?.searchMatchContext?.kind == .semantic)
        }

        @Test
        func hybridCursorRestartsWhenEitherIndexRevisionChanges() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let vault = makeVault(name: "Cursor")
            let meetings = (0 ..< 3).map {
                makeMeeting(vaultID: vault.id, name: "Semantic \($0)", description: body("\($0)"))
            }
            try await database.dbQueue.write { db in
                try vault.insert(db)
                for meeting in meetings {
                    try meeting.insert(db)
                }
            }
            await database.searchIndexer.drain()
            try await installVectors(
                meetings.enumerated().map { ($1.id, 0.90 - Float($0) * 0.10) },
                in: database
            )

            let first = try await search(vaultID: vault.id, database: database)
            let cursor = try #require(first.nextCursor)
            let second = try await search(vaultID: vault.id, cursor: cursor, database: database)
            #expect(first.items.map(\.id) == [meetings[0].id])
            #expect(second.items.map(\.id) == [meetings[1].id])
            #expect(!second.replacesResults)

            try await database.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE search_index_state SET indexRevision = indexRevision + 1 WHERE indexKind = 'fts'"
                )
            }
            let afterFTSChange = try await search(vaultID: vault.id, cursor: cursor, database: database)
            #expect(afterFTSChange.items.map(\.id) == [meetings[0].id])
            #expect(afterFTSChange.replacesResults)

            let refreshedCursor = try #require(afterFTSChange.nextCursor)
            try await database.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE search_index_state SET indexRevision = indexRevision + 1 WHERE indexKind = 'vector'"
                )
            }
            let afterVectorChange = try await search(vaultID: vault.id, cursor: refreshedCursor, database: database)
            #expect(afterVectorChange.items.map(\.id) == [meetings[0].id])
            #expect(afterVectorChange.replacesResults)
        }

        @Test
        func vectorFailureAppearsInTheVectorSettingsSection() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            try await database.dbQueue.write { db in
                try db.execute(
                    sql: """
                    UPDATE search_index_state
                    SET phase = 'failed', lastErrorCode = 'VectorFailure', analyzerConfigurationHash = ?
                    WHERE indexKind = 'vector'
                    """,
                    arguments: [EmbeddingGemmaDescriptor.configurationHash]
                )
            }
            let settings = SearchSettingsModel(database: database)

            await settings.refresh()

            #expect(settings.vectorLastErrorCode == "VectorFailure")
            #expect(settings.lastErrorCode == nil)
        }

        private func search(
            vaultID: UUID,
            cursor: MeetingSearchCursor? = nil,
            database: AppDatabaseManager
        ) async throws -> MeetingSearchPage {
            try await MeetingRepository.searchMeetingSidebarPage(
                vaultId: vaultID,
                query: "semantic-cursor-query",
                mode: .neural,
                queryEmbedding: unitVector(similarity: 1),
                after: cursor,
                limit: 1,
                dbQueue: database.dbQueue
            )
        }

        private func installVectors(
            _ vectors: [(meetingID: UUID, similarity: Float)],
            in database: AppDatabaseManager
        ) async throws {
            try await database.dbQueue.write { db in
                for vector in vectors {
                    try db.execute(
                        sql: """
                        INSERT INTO search_documents_vec(
                            documentId, embedding, sourceContentHash, indexGeneration, updatedAt
                        ) SELECT id, ?, sourceContentHash, 1, ? FROM search_documents
                        WHERE kind = 'meeting' AND meetingId = ?
                        """,
                        arguments: [EmbeddingVector.encode(unitVector(similarity: vector.similarity)), Date(), vector.meetingID]
                    )
                }
                try db.execute(
                    sql: """
                    UPDATE search_index_state
                    SET isEnabled = 1, phase = 'ready', analyzerConfigurationHash = ?
                    WHERE indexKind = 'vector'
                    """,
                    arguments: [EmbeddingGemmaDescriptor.configurationHash]
                )
            }
        }

        private func installProjectVectors(
            _ vectors: [(projectID: UUID, similarity: Float)],
            in database: AppDatabaseManager
        ) async throws {
            try await database.dbQueue.write { db in
                for vector in vectors {
                    try db.execute(
                        sql: """
                        INSERT INTO search_documents_vec(
                            documentId, embedding, sourceContentHash, indexGeneration, updatedAt
                        ) SELECT id, ?, sourceContentHash, 1, ? FROM search_documents
                        WHERE kind = 'project' AND projectId = ?
                        """,
                        arguments: [EmbeddingVector.encode(unitVector(similarity: vector.similarity)), Date(), vector.projectID]
                    )
                }
            }
        }

        private nonisolated func unitVector(similarity: Float) -> [Float] {
            [similarity, sqrt(max(0, 1 - similarity * similarity))]
                + Array(repeating: 0, count: EmbeddingGemmaDescriptor.dimensions - 2)
        }

        private func body(_ marker: String) -> String {
            marker + String(repeating: " semantic meeting content", count: 5)
        }

        private func makeVault(name: String) -> VaultRecord {
            VaultRecord(
                id: .v7(),
                path: "/tmp/hybrid-\(name)-\(UUID.v7())",
                name: name,
                createdAt: .now,
                lastOpenedAt: .now
            )
        }

        private func makeProject(vaultID: UUID, parentID: UUID? = nil, name: String) -> ProjectRecord {
            ProjectRecord(
                id: .v7(),
                vaultId: vaultID,
                parentProjectId: parentID,
                name: name,
                createdAt: .now,
                projectType: parentID == nil ? .undefined : nil
            )
        }

        private func makeMeeting(
            vaultID: UUID,
            projectID: UUID? = nil,
            name: String,
            description: String? = nil,
            date: Date = .now
        ) -> MeetingRecord {
            MeetingRecord(
                id: .v7(),
                vaultId: vaultID,
                projectId: projectID,
                name: name,
                description: description ?? body(name),
                createdAt: date,
                updatedAt: date,
                recordingStartedAt: date
            )
        }
    }
#endif
