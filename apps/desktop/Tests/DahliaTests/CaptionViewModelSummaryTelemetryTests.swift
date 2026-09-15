import Foundation
import GRDB
@testable import Dahlia
@testable import DahliaRuntimeSupport

#if canImport(Testing)
    import Testing

    @MainActor
    struct CaptionViewModelSummaryTelemetryTests {
        @Test
        func successfulManualSummaryEmitsOneStartAndOneCompletion() async throws {
            let fixture = try SummaryGenerationFixture()
            defer { fixture.removeFiles() }
            var events: [UsageTelemetryEvent] = []
            let viewModel = CaptionViewModel(
                summaryGenerationRunner: { input in
                    .init(
                        document: SummaryDocument(title: "Generated", sections: []),
                        fileName: "summary.md",
                        markdown: input.transcriptText
                    )
                },
                usageTelemetryReporter: { events.append($0) }
            )
            let options = SummaryGenerationOptions(
                exportOptions: .init(exportsToWorkspace: false, exportsToGoogleDocs: false)
            )

            await fixture.select(fixture.first, in: viewModel, note: "note")
            #expect(await waitUntil { viewModel.canGenerateSummary })
            #expect(viewModel.triggerManualSummary(options: options))
            #expect(await waitUntil { !viewModel.isSummaryGenerating(meetingId: fixture.first.id) })
            #expect(events == [
                .summary(.started, trigger: .manual),
                .summary(.completed, trigger: .manual),
            ])
        }

        @Test
        func persistenceFailureDoesNotStartWorkspaceExport() async throws {
            let fixture = try SummaryGenerationFixture()
            defer { fixture.removeFiles() }
            let runner = BlockingSummaryRunner()
            var events: [UsageTelemetryEvent] = []
            let viewModel = CaptionViewModel(
                summaryGenerationRunner: runner.run,
                usageTelemetryReporter: { events.append($0) }
            )
            let options = SummaryGenerationOptions(
                exportOptions: .init(exportsToWorkspace: true, exportsToGoogleDocs: false)
            )

            await fixture.select(fixture.first, in: viewModel, note: "note")
            #expect(await waitUntil { viewModel.canGenerateSummary })
            #expect(viewModel.triggerManualSummary(options: options))
            try await runner.waitForCallCount(1)
            try await fixture.database.dbQueue.write { db in
                try db.execute(sql: "DROP TABLE summaries")
            }
            runner.complete(meetingID: fixture.first.id, title: "Generated")
            #expect(await waitUntil { !viewModel.isSummaryGenerating(meetingId: fixture.first.id) })

            #expect(events == [
                .summary(.started, trigger: .manual),
                .summary(.failed(.generation), trigger: .manual),
            ])
        }

        @Test
        func restoredServerRetranscriptionUsesOnlyBatchTranscriptionAccounting() async throws {
            let batch = try BatchAudioTestFixture(name: "server-retranscription-telemetry", endedAt: .now, batchCompletedAt: .now)
            defer { batch.removeFiles() }
            let connectionID = UUID.v7()
            let origin = "https://retranscription-telemetry-\(connectionID.uuidString.lowercased()).test"
            try await batch.database.dbQueue.write { db in
                try DahliaAccountConnectionRecord(
                    id: connectionID,
                    origin: origin,
                    clientID: "test",
                    createdAt: .now
                ).insert(db)
                var workspace = try #require(try WorkspaceRecord.fetchOne(db, key: batch.meeting.workspaceId))
                workspace.accountConnectionId = connectionID
                workspace.organizationId = .v7()
                workspace.syncRole = "admin"
                workspace.syncConfirmedConnectionId = connectionID
                workspace.syncPullCursor = "ready"
                workspace.generationSettings.processing.location = .remote
                try workspace.update(db)
            }
            let workspace = try await batch.database.dbQueue.read { db in
                try #require(try WorkspaceRecord.fetchOne(db, key: batch.meeting.workspaceId))
            }
            let processing = RecordingProcessing(
                id: .v7(),
                automatic: true,
                liveDraft: false,
                localeIdentifier: "ja_JP",
                method: .cloudTranscription,
                options: .manual,
                generationSettings: SummaryGenerationSettings.current(workspace: workspace).applying(options: .manual),
                workspaceSettings: workspace.generationSettings,
                summaryMode: .remote,
                sessionIDs: [batch.session.id],
                stage: .uploading,
                transcriptionOnly: true
            )
            try await batch.database.dbQueue.write { db in
                try processing.save(sessionID: batch.session.id, in: db)
            }
            ImageURLProtocol.register(origin: origin) { _ in (503, [:], Data()) }
            defer { ImageURLProtocol.remove(origin: origin) }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ImageURLProtocol.self]
            var events: [UsageTelemetryEvent] = []
            let viewModel = CaptionViewModel(
                serverSummaryService: ServerSummaryService(client: SyncAPIClient(
                    session: URLSession(configuration: configuration),
                    tokenProvider: { _, _ in "test" }
                )),
                usageTelemetryReporter: { events.append($0) }
            )

            try await viewModel.restoreRecordingProcessingForTesting(dbQueue: batch.database.dbQueue)
            #expect(await waitUntil { events.count == 2 })
            let job = try #require(viewModel.summaryGenerationJobs.first)
            #expect(job.transcriptionOnly)
            #expect(job.progress.summaryGeneration.isSkipped)
            #expect(!viewModel.isSummaryGenerating(meetingId: batch.meeting.id))
            #expect(viewModel.summaryError == nil)
            #expect(events == [
                .transcription(.started, mode: .batch),
                .transcription(.failed(.transcription), mode: .batch),
            ])
        }

        @Test
        func cancelledRetranscriptionClearsPendingFlowAndAllowsFreshTelemetry() async throws {
            let batch = try BatchAudioTestFixture(
                name: "cancelled-retranscription-telemetry",
                endedAt: .now,
                batchCompletedAt: .now
            )
            defer { batch.removeFiles() }
            try await batch.recordMicrophoneAudio()
            let processing = RecordingProcessing(
                id: .v7(),
                automatic: true,
                liveDraft: false,
                localeIdentifier: "en_US",
                method: .transcript,
                options: .manual,
                generationSettings: .current(detailLevel: .standard),
                workspaceSettings: nil,
                sessionIDs: [batch.session.id],
                stage: .transcribing,
                transcriptionOnly: true
            )
            _ = try await BatchTranscriptionConfirmationService.confirmRetranscription(
                sessionIds: [batch.session.id],
                processing: processing,
                processingSessionID: batch.session.id,
                languageSelection: .manual(localeIdentifier: "en_US"),
                automaticLanguageCandidates: nil,
                dbQueue: batch.database.dbQueue
            )
            var events: [UsageTelemetryEvent] = []
            let viewModel = CaptionViewModel(usageTelemetryReporter: { events.append($0) })
            viewModel.registerPendingBatchSummaryForTesting(
                sessionID: batch.session.id,
                meetingID: batch.meeting.id,
                options: .manual,
                dbQueue: batch.database.dbQueue,
                workspaceURL: batch.workspaceURL,
                processing: processing
            )
            await viewModel.handleBatchTranscriptionUpdate(.init(
                meetingId: batch.meeting.id,
                state: .queued(sessionId: batch.session.id)
            ))
            let job = try #require(viewModel.summaryGenerationJobs.first)
            let cancel = try #require(job.cancel)
            cancel()
            #expect(await waitUntil { job.isCancelled })

            #expect(viewModel.pendingBatchSummaryRequestCountForTesting == 0)
            await viewModel.handleBatchTranscriptionUpdate(.init(
                meetingId: batch.meeting.id,
                state: .queued(sessionId: batch.session.id)
            ))
            #expect(events == [
                .transcription(.started, mode: .batch),
                .transcription(.started, mode: .batch),
            ])
        }

        private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
            await pollUntil { condition() }
        }
    }
#endif
