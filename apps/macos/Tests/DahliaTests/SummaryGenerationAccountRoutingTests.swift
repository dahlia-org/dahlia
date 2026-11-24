#if canImport(Testing)
    import Foundation
    import GRDB
    import Testing
    @testable import Dahlia

    @MainActor
    struct SummaryGenerationAccountRoutingTests {

        @Test
        func manualAudioNeverFallsBackToLocalTranscriptGeneration() async throws {
            let fixture = try SummaryGenerationFixture()
            defer { fixture.removeFiles() }
            _ = try attachServerAccount(to: fixture)
            var generationCalls = 0
            let viewModel = CaptionViewModel(
                summaryGenerationRunner: { _ in
                    generationCalls += 1
                    throw CancellationError()
                }
            )
            await fixture.select(fixture.first, in: viewModel, note: "note")

            let options = SummaryGenerationOptions(exportOptions: .manual, source: .audio)
            #expect(viewModel.triggerManualSummary(options: options))
            let job = try #require(viewModel.summaryGenerationJobs.first)
            await job.task?.value

            #expect(generationCalls == 0)
            #expect(job.hasFailure)
        }

        private func attachServerAccount(to fixture: SummaryGenerationFixture) throws -> UUID {
            let connection = DahliaAccountConnectionRecord(
                id: .v7(), origin: "https://summary-routing-\(UUID.v7().uuidString.lowercased()).invalid", clientID: "test", createdAt: .now
            )
            try fixture.database.dbQueue.write { db in
                try connection.insert(db)
                try WorkspaceRecord.filter(key: fixture.workspace.id).updateAll(
                    db,
                    Column("accountConnectionId").set(to: connection.id),
                    Column("organizationId").set(to: UUID.v7()),
                    Column("syncRole").set(to: "admin"),
                    Column("syncConfirmedConnectionId").set(to: connection.id),
                    Column("syncPullCursor").set(to: "ready")
                )
                var workspace = try WorkspaceRecord.fetchOne(db, key: fixture.workspace.id)!
                workspace.generationSettings.outputLanguage = .fr
                workspace.generationSettings.summary.style = .concise
                try workspace.update(db)
                for meeting in [fixture.first, fixture.second] {
                    try db.execute(
                        sql: "INSERT INTO sync_entity_state(workspace_id, entity, entityId, confirmedRevision) VALUES (?, 'meeting', ?, 1)",
                        arguments: [workspace.id, meeting.id]
                    )
                }
            }
            return connection.id
        }
    }
#endif
