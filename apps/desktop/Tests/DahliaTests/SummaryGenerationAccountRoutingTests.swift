#if canImport(Testing)
    import Foundation
    import GRDB
    import Testing
    @testable import Dahlia

    @MainActor
    struct SummaryGenerationAccountRoutingTests {
        @Test(arguments: [false, true])
        func serverRequestsUseMacInferenceThroughTheirOwnGateway(bulk: Bool) async throws {
            let fixture = try SummaryGenerationFixture()
            defer { fixture.removeFiles() }
            let connectionID = try attachServerAccount(to: fixture)
            let origin = try await fixture.database.dbQueue.read { db in
                try #require(try DahliaAccountConnectionRecord.fetchOne(db, key: connectionID)).origin
            }
            ImageURLProtocol.register(origin: origin) { request in
                if request.url!.path.hasSuffix("/capabilities") { return (200, [:], Data(#"{"documents":{"version":3}}"#.utf8)) }
                return (200, [:], Data(#"{"document":null}"#.utf8))
            }
            defer { ImageURLProtocol.remove(origin: origin) }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ImageURLProtocol.self]
            let documentSync = DocumentSyncService.shared(
                dbQueue: fixture.database.dbQueue,
                api: SyncAPIClient(session: URLSession(configuration: configuration), tokenProvider: { _, _ in "test" })
            )
            defer { withExtendedLifetime(documentSync) {} }
            var generatedSettings: [SummaryGenerationSettings] = []
            let viewModel = CaptionViewModel(summaryGenerationRunner: { input in
                generatedSettings.append(input.generationSettings)
                throw CancellationError()
            })
            await fixture.select(fixture.first, in: viewModel, note: "note")
            if bulk {
                viewModel.triggerManualSummaries(
                    meetingIds: [fixture.first.id, fixture.second.id], dbQueue: fixture.database.dbQueue, workspaceURL: nil
                )
            } else {
                try #require(viewModel.triggerManualSummary())
            }
            let jobs = viewModel.summaryGenerationJobs
            #expect(jobs.count == (bulk ? 2 : 1))
            for job in jobs {
                await job.task?.value
            }
            #expect(generatedSettings.count == (bulk ? 2 : 1))
            for settings in generatedSettings {
                #expect(settings.runtimeProvider == .dahlia(connectionID: connectionID))
                #expect(settings.sourceAccountConnectionID == connectionID)
                #expect(settings.languageDisplayName == SummaryLanguage.fr.displayName)
            }

        }

        @Test
        func serverRecordingCannotOverrideSummaryRoutingToLocal() async throws {
            let fixture = try SummaryGenerationFixture()
            defer { fixture.removeFiles() }
            let connectionID = try attachServerAccount(to: fixture)
            var generationCalls = 0
            let viewModel = CaptionViewModel(summaryGenerationRunner: { input in
                generationCalls += 1
                #expect(input.generationSettings.sourceAccountConnectionID == connectionID)
                throw CancellationError()
            })
            await fixture.select(fixture.first, in: viewModel, note: "note")
            let sessionID = try fixture.insertRecordingSession(for: fixture.first, offset: 0)
            var generationSettings = SummaryGenerationSettings.current()
            generationSettings.accountConnectionID = connectionID
            generationSettings.workspaceID = fixture.workspace.id
            let processing = RecordingProcessing(
                id: .v7(), automatic: true, liveDraft: false, localeIdentifier: "en_US", method: .transcript,
                options: .manual, generationSettings: generationSettings, workspaceSettings: nil,
                summaryMode: .local, sessionIDs: [sessionID], stage: .transcribing
            )
            try await fixture.database.dbQueue.write { db in try processing.save(sessionID: sessionID, in: db) }
            viewModel.registerPendingBatchSummaryForTesting(
                sessionID: sessionID, meetingID: fixture.first.id, options: .manual,
                dbQueue: fixture.database.dbQueue, workspaceURL: fixture.workspaceURL,
                generationSettings: generationSettings, processing: processing
            )
            await viewModel.handleBatchTranscriptionUpdate(.init(meetingId: fixture.first.id, state: .completed(sessionId: sessionID)))
            for job in viewModel.summaryGenerationJobs {
                await job.task?.value
            }
            #expect(generationCalls == 0)
        }

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
