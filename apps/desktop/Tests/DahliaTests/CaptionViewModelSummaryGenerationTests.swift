import Foundation
import GRDB
@testable import Dahlia
@testable import DahliaRuntimeSupport

#if canImport(Testing)
    import Testing

    @MainActor
    @Suite(.serialized)
    // swiftlint:disable:next type_body_length
    struct CaptionViewModelSummaryGenerationTests {
        @Test
        func generatedSummaryWinsOverAnEarlierReload() async throws {
            let fixture = try SummaryGenerationFixture()
            defer { fixture.removeFiles() }
            let runner = BlockingSummaryRunner()
            let loader = BlockingSummaryDocumentLoader()
            let viewModel = CaptionViewModel(
                summaryGenerationRunner: runner.run,
                summaryDocumentLoader: loader.load
            )
            let options = SummaryGenerationOptions(
                exportOptions: SummaryExportOptions(exportsToVault: false, exportsToGoogleDocs: false)
            )

            await fixture.select(fixture.first, in: viewModel, note: "note")
            viewModel.reloadSummaryDocument()
            await loader.waitForCall()

            #expect(viewModel.triggerManualSummary(options: options))
            await runner.waitForCallCount(1)
            runner.complete(meetingID: fixture.first.id, title: "Generated")
            #expect(await waitUntil { !viewModel.isSummaryGenerating(meetingId: fixture.first.id) })

            loader.complete(document: SummaryDocument(title: "Stale", sections: []))
            #expect(await waitUntil { viewModel.currentSummaryDocument?.title == "Generated" })
        }

        @Test
        func googleDocsExportDoesNotAttachToASummaryChangedDuringUpload() async throws {
            let fixture = try SummaryGenerationFixture()
            defer { fixture.removeFiles() }
            let exporter = BlockingGoogleDocsSummaryExporter()
            let viewModel = CaptionViewModel(googleDocsSummaryExporter: exporter.export)
            let repository = MeetingRepository(dbQueue: fixture.database.dbQueue)
            try repository.applyGeneratedSummary(
                toMeetingId: fixture.first.id,
                document: SummaryDocument(title: "Original", sections: []),
                tags: []
            )
            await fixture.select(fixture.first, in: viewModel, note: "note")
            #expect(await waitUntil { viewModel.currentSummaryDocument?.title == "Original" })

            let export = Task { await viewModel.exportCurrentSummaryToGoogleDocs() }
            await exporter.waitForCall()
            try repository.applyGeneratedSummary(
                toMeetingId: fixture.first.id,
                document: SummaryDocument(title: "Corrected", sections: []),
                tags: []
            )
            exporter.complete(fileId: "stale-file")

            let exported = await export.value
            #expect(!exported)
            let googleExport = try await fixture.database.dbQueue.read { db in
                try SummaryExportRecord.fetchOne(
                    meetingId: fixture.first.id,
                    type: .googleDocs,
                    in: db
                )
            }
            #expect(googleExport == nil)
            #expect(try repository.fetchSummary(forMeetingId: fixture.first.id)?.loadDocument().title == "Corrected")
        }

        @Test
        func artifactExportDeletesANewArtifactWhenSummaryChangesDuringUpload() async throws {
            let fixture = try SummaryGenerationFixture()
            defer { fixture.removeFiles() }
            let exporter = BlockingArtifactSummaryExporter()
            let deleter = ArtifactDeleteRecorder()
            let viewModel = CaptionViewModel(
                artifactSummaryExporter: exporter.export,
                artifactSummaryDeleter: { url, connectionID, origin in
                    await deleter.delete(url: url, connectionID: connectionID, origin: origin)
                }
            )
            let repository = MeetingRepository(dbQueue: fixture.database.dbQueue)
            try repository.applyGeneratedSummary(
                toMeetingId: fixture.first.id,
                document: SummaryDocument(title: "Original", sections: []),
                tags: []
            )
            await fixture.select(fixture.first, in: viewModel, note: "note")
            #expect(await waitUntil { viewModel.currentSummaryDocument?.title == "Original" })
            let connection = DahliaAccountConnection(
                record: DahliaAccountConnectionRecord(
                    id: .v7(),
                    origin: "https://dahlia.example",
                    clientID: "desktop",
                    createdAt: .now
                ),
                account: DahliaCloudAccount(id: "user", name: "User", email: nil),
                isCloud: false,
                grantedScopes: [DahliaArtifactExportService.requiredScope]
            )
            let artifactURL = try #require(URL(
                string: "https://dahlia.example/api/v1/artifacts/019cc4dd-e5c5-7bd4-94e0-98df9cc40db9"
            ))

            let export = Task { await viewModel.exportCurrentSummaryToDahliaArtifact(connection: connection) }
            await exporter.waitForCall()
            try repository.applyGeneratedSummary(
                toMeetingId: fixture.first.id,
                document: SummaryDocument(title: "Corrected", sections: []),
                tags: []
            )
            await exporter.complete(result: DahliaArtifactExportResult(url: artifactURL, wasCreated: true))

            #expect(await export.value == false)
            #expect(await deleter.deletedURLs == [artifactURL])
            let artifactExport = try await fixture.database.dbQueue.read { db in
                try SummaryExportRecord.fetchOne(
                    meetingId: fixture.first.id,
                    type: .dahliaArtifact,
                    in: db
                )
            }
            #expect(artifactExport == nil)
        }

        @Test
        func manualSummaryUsesProjectSelectedBeforeGeneration() async throws {
            let fixture = try SummaryGenerationFixture()
            defer { fixture.removeFiles() }
            let runner = BlockingSummaryRunner()
            let viewModel = CaptionViewModel(summaryGenerationRunner: runner.run)
            let project = try fixture.insertProject(name: "Selected", description: "Selected context")
            let options = SummaryGenerationOptions(
                exportOptions: SummaryExportOptions(exportsToVault: false, exportsToGoogleDocs: false)
            )

            await fixture.select(fixture.first, in: viewModel, note: "note")
            #expect(viewModel.assignCurrentMeetingProject(project.id) == nil)
            viewModel.triggerManualSummary(options: options)
            await runner.waitForCallCount(1)

            #expect(runner.calls[0].projectName == project.path)
            #expect(runner.calls[0].projectDescription == "Selected context")
            runner.complete(meetingID: fixture.first.id, title: "Summary")
            #expect(await waitUntil { !viewModel.isSummaryGenerating(meetingId: fixture.first.id) })
        }

        @Test
        func backgroundSummaryUsesRecordingStartInsteadOfMeetingCreationTime() async throws {
            let fixture = try SummaryGenerationFixture()
            defer { fixture.removeFiles() }
            let runner = BlockingSummaryRunner()
            let viewModel = CaptionViewModel(summaryGenerationRunner: runner.run)
            let recordingStartedAt = fixture.first.createdAt.addingTimeInterval(600)
            try await fixture.database.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE meetings SET recordingStartedAt = ? WHERE id = ?",
                    arguments: [recordingStartedAt, fixture.first.id]
                )
            }

            viewModel.triggerManualSummaries(
                meetingIds: [fixture.first.id],
                dbQueue: fixture.database.dbQueue,
                vaultURL: fixture.vaultURL,
                options: SummaryGenerationOptions(
                    exportOptions: SummaryExportOptions(exportsToVault: false, exportsToGoogleDocs: false)
                )
            )
            await runner.waitForCallCount(1)

            #expect(runner.calls[0].recordedAt == recordingStartedAt)
            runner.complete(meetingID: fixture.first.id, title: "Summary")
            #expect(await waitUntil { !viewModel.isSummaryGenerating(meetingId: fixture.first.id) })
        }

        @Test
        func summaryExportUsesProjectPathUpdatedDuringGeneration() async throws {
            let fixture = try SummaryGenerationFixture()
            defer { fixture.removeFiles() }
            let runner = BlockingSummaryRunner()
            let viewModel = CaptionViewModel(summaryGenerationRunner: runner.run)
            let project = try fixture.insertProject(name: "Original", description: "")
            let options = SummaryGenerationOptions(
                exportOptions: SummaryExportOptions(exportsToVault: true, exportsToGoogleDocs: false)
            )
            await fixture.select(fixture.first, in: viewModel, note: "note")
            #expect(viewModel.assignCurrentMeetingProject(project.id) == nil)
            #expect(viewModel.triggerManualSummary(options: options))
            await runner.waitForCallCount(1)

            let repository = MeetingRepository(dbQueue: fixture.database.dbQueue)
            let service = ProjectWorkspaceService(repository: repository, vault: fixture.vault)
            _ = try service.renameProject(id: project.id, newName: "Renamed")
            runner.complete(meetingID: fixture.first.id, title: "Summary")

            #expect(await waitUntil { !viewModel.isSummaryGenerating(meetingId: fixture.first.id) })
            #expect(try fixture.summaryPath(for: fixture.first.id) == "Renamed/summary.md")
            #expect(FileManager.default.fileExists(
                atPath: fixture.vaultURL.appending(path: "Renamed/summary.md").path
            ))
            #expect(!FileManager.default.fileExists(
                atPath: fixture.vaultURL.appending(path: "Original/summary.md").path
            ))
        }

        @Test
        func summaryRegenerationReusesTrackedVaultPath() async throws {
            let fixture = try SummaryGenerationFixture()
            defer { fixture.removeFiles() }
            let runner = BlockingSummaryRunner()
            let viewModel = CaptionViewModel(summaryGenerationRunner: runner.run)
            let project = try fixture.insertProject(name: "Project", description: "")
            try fixture.assign(fixture.first, to: project)
            let existingURL = fixture.vaultURL.appending(path: "Project/Existing.md")
            try Data("Old summary".utf8).write(to: existingURL)
            let repository = MeetingRepository(dbQueue: fixture.database.dbQueue)
            try repository.upsertSummary(SummaryRecord(
                meetingId: fixture.first.id,
                title: "Old summary",
                document: SummaryDocument(title: "Old summary", sections: []).databaseJSONString(),
                createdAt: .now
            ))
            try repository.updateSummaryVaultRelativePath(
                forMeetingId: fixture.first.id,
                relativePath: "Project/Existing.md"
            )
            let options = SummaryGenerationOptions(
                exportOptions: SummaryExportOptions(exportsToVault: true, exportsToGoogleDocs: false)
            )

            await fixture.select(fixture.first, in: viewModel, note: "note")
            #expect(viewModel.triggerManualSummary(options: options))
            await runner.waitForCallCount(1)
            runner.complete(meetingID: fixture.first.id, title: "New summary")

            #expect(await waitUntil { !viewModel.isSummaryGenerating(meetingId: fixture.first.id) })
            #expect(try fixture.summaryPath(for: fixture.first.id) == "Project/Existing.md")
            #expect(try String(contentsOf: existingURL, encoding: .utf8) == "New summary")
            #expect(!FileManager.default.fileExists(
                atPath: fixture.vaultURL.appending(path: "Project/summary-\(fixture.first.id.uuidString).md").path
            ))
        }

        @Test
        func batchConfirmationWithoutPersistenceContextDoesNotBlockTranscription() async throws {
            let fixture = try SummaryGenerationFixture()
            defer { fixture.removeFiles() }
            let viewModel = CaptionViewModel()
            let sessionID = try fixture.insertRecordingSession(for: fixture.first, offset: 0)

            await viewModel.presentBatchTranscriptionConfirmation(
                sessionId: sessionID,
                meetingId: fixture.first.id,
                dbQueue: fixture.database.dbQueue
            )

            let confirmation = try #require(viewModel.pendingBatchTranscriptionConfirmation)
            #expect(confirmation.projectSelection == .unavailable)
            #expect(viewModel.assignPendingBatchTranscriptionProject(nil) == nil)
        }

        @Test
        func manualSummaryReportsWhenGenerationBecomesUnavailable() async throws {
            let fixture = try SummaryGenerationFixture()
            defer { fixture.removeFiles() }
            let runner = BlockingSummaryRunner()
            let viewModel = CaptionViewModel(summaryGenerationRunner: runner.run)
            await fixture.select(fixture.first, in: viewModel, note: "note")
            viewModel.setScreenshotDeletionInProgressForTesting(true)

            #expect(!viewModel.triggerManualSummary(options: .manual))
            #expect(runner.calls.isEmpty)
            #expect(viewModel.summaryGenerationJobs.isEmpty)
        }

        @Test
        func automaticBatchSummaryReloadsProjectSelectedAtConfirmation() async throws {
            let fixture = try SummaryGenerationFixture()
            defer { fixture.removeFiles() }
            let runner = BlockingSummaryRunner()
            let viewModel = CaptionViewModel(summaryGenerationRunner: runner.run)
            let project = try fixture.insertProject(name: "Batch", description: "Batch context")
            try fixture.assign(fixture.first, to: project)
            let sessionID = try fixture.insertRecordingSession(for: fixture.first, offset: 0)
            let options = SummaryGenerationOptions(
                exportOptions: SummaryExportOptions(exportsToVault: false, exportsToGoogleDocs: false),
                detailLevel: .eventSession
            )

            viewModel.registerPendingBatchSummaryForTesting(
                sessionID: sessionID,
                meetingID: fixture.first.id,
                options: options,
                dbQueue: fixture.database.dbQueue,
                vaultURL: fixture.vaultURL
            )
            let job = try #require(viewModel.summaryGenerationJobs.first)
            let progress = BatchTranscriptionProgress(completedFileCount: 2, totalFileCount: 5)
            await viewModel.handleBatchTranscriptionUpdate(.init(
                meetingId: fixture.first.id,
                state: .running(sessionId: sessionID, progress: progress)
            ))

            #expect(job.progress.transcriptionProgress == 0.4)
            #expect(!job.progress.transcription.isTerminal)

            await viewModel.handleBatchTranscriptionUpdate(.init(
                meetingId: fixture.first.id,
                state: .completed(sessionId: sessionID)
            ))
            await runner.waitForCallCount(1)

            #expect(viewModel.summaryGenerationJobs.first?.id == job.id)
            #expect(job.progress.transcription.isTerminal)
            #expect(job.progress.transcriptionProgress == nil)
            #expect(runner.calls[0].projectName == project.path)
            #expect(runner.calls[0].projectDescription == "Batch context")
            #expect(runner.calls[0].settings.detailLevelInstruction == SummaryDetailLevel.eventSession.instruction)
            runner.complete(meetingID: fixture.first.id, title: "Summary")
            #expect(await waitUntil { !viewModel.isSummaryGenerating(meetingId: fixture.first.id) })
        }

        @Test
        func selectedMeetingsRegenerateConcurrentlyWithoutChangingCurrentMeeting() async throws {
            let fixture = try SummaryGenerationFixture()
            defer { fixture.removeFiles() }
            let runner = BlockingSummaryRunner()
            let viewModel = CaptionViewModel(summaryGenerationRunner: runner.run)
            let meetingIDs: Set<UUID> = [fixture.first.id, fixture.second.id]
            let options = SummaryGenerationOptions(
                exportOptions: SummaryExportOptions(exportsToVault: false, exportsToGoogleDocs: false),
                detailLevel: .standard
            )

            #expect(viewModel.canRegenerateSummaries(meetingIds: meetingIDs))
            viewModel.triggerManualSummaries(
                meetingIds: meetingIDs,
                dbQueue: fixture.database.dbQueue,
                vaultURL: fixture.vaultURL,
                options: options
            )
            await runner.waitForCallCount(2)

            #expect(Set(runner.calls.map(\.meetingID)) == meetingIDs)
            #expect(runner.calls.allSatisfy {
                $0.settings.detailLevelInstruction == SummaryDetailLevel.standard.instruction
            })
            #expect(viewModel.summaryGeneratingMeetingIDs == meetingIDs)
            #expect(!viewModel.canRegenerateSummaries(meetingIds: meetingIDs))
            #expect(viewModel.currentMeetingId == nil)

            runner.complete(meetingID: fixture.first.id, title: "First regenerated")
            runner.complete(meetingID: fixture.second.id, title: "Second regenerated")
            #expect(await waitUntil { viewModel.summaryGeneratingMeetingIDs.isEmpty })
            #expect(try fixture.summary(for: fixture.first.id) != nil)
            #expect(try fixture.summary(for: fixture.second.id) != nil)
            #expect(viewModel.currentMeetingId == nil)
        }

        @Test
        func selectedMeetingRegenerationSkipsMeetingAlreadyGenerating() async throws {
            let fixture = try SummaryGenerationFixture()
            defer { fixture.removeFiles() }
            let runner = BlockingSummaryRunner()
            let viewModel = CaptionViewModel(summaryGenerationRunner: runner.run)
            let meetingIDs: Set<UUID> = [fixture.first.id, fixture.second.id]
            let options = SummaryGenerationOptions(
                exportOptions: SummaryExportOptions(exportsToVault: false, exportsToGoogleDocs: false)
            )

            await fixture.select(fixture.first, in: viewModel, note: "first")
            viewModel.triggerManualSummary(options: options)
            await runner.waitForCallCount(1)

            #expect(viewModel.canRegenerateSummaries(meetingIds: meetingIDs))
            viewModel.triggerManualSummaries(
                meetingIds: meetingIDs,
                dbQueue: fixture.database.dbQueue,
                vaultURL: fixture.vaultURL,
                options: options
            )
            await runner.waitForCallCount(2)

            #expect(runner.calls.count(where: { $0.meetingID == fixture.first.id }) == 1)
            #expect(runner.calls.count(where: { $0.meetingID == fixture.second.id }) == 1)

            runner.complete(meetingID: fixture.first.id, title: "First")
            runner.complete(meetingID: fixture.second.id, title: "Second")
            #expect(await waitUntil { viewModel.summaryGeneratingMeetingIDs.isEmpty })
        }

        @Test
        func differentMeetingsRunConcurrentlyAndOnlyUpdateTheirOwnSelection() async throws {
            let fixture = try SummaryGenerationFixture()
            defer { fixture.removeFiles() }
            let runner = BlockingSummaryRunner()
            let viewModel = CaptionViewModel(summaryGenerationRunner: runner.run)
            let options = SummaryGenerationOptions(
                exportOptions: SummaryExportOptions(exportsToVault: false, exportsToGoogleDocs: false)
            )

            await fixture.select(fixture.first, in: viewModel, note: "first note")
            viewModel.triggerManualSummary(options: options)
            await runner.waitForCallCount(1)

            await fixture.select(fixture.second, in: viewModel, note: "second note")
            viewModel.triggerManualSummary(options: options)
            await runner.waitForCallCount(2)

            #expect(viewModel.summaryGeneratingMeetingIDs == [fixture.first.id, fixture.second.id])
            #expect(runner.calls.map(\.meetingID) == [fixture.first.id, fixture.second.id])
            #expect(runner.calls.map(\.noteText) == ["first note", "second note"])

            runner.complete(meetingID: fixture.first.id, title: "First summary")
            #expect(await waitUntil { !viewModel.isSummaryGenerating(meetingId: fixture.first.id) })
            #expect(viewModel.isSummaryGenerating(meetingId: fixture.second.id))
            #expect(viewModel.currentSummaryDocument == nil)

            runner.complete(meetingID: fixture.second.id, title: "Second summary")
            #expect(await waitUntil { !viewModel.isSummaryGenerating(meetingId: fixture.second.id) })
            #expect(viewModel.currentSummaryDocument?.title == "Second summary")

            let firstStored = try fixture.summary(for: fixture.first.id)
            let secondStored = try fixture.summary(for: fixture.second.id)
            #expect(try firstStored?.loadDocument().title == "First summary")
            #expect(try secondStored?.loadDocument().title == "Second summary")
        }

        @Test
        func settingsAreFrozenAndFailedJobSurvivesRetryUntilDismissed() async throws {
            let fixture = try SummaryGenerationFixture()
            defer { fixture.removeFiles() }
            let runner = BlockingSummaryRunner()
            let sleeper = ControlledSummaryJobSleeper()
            let settings = AppSettings.shared
            let vaultSettings = VaultAISettingsModel.shared
            let originalModel = settings.codexModelID
            let originalEffort = settings.codexReasoningEffort
            let originalVaultModel = vaultSettings.summaryModelID
            let originalVaultEffort = vaultSettings.summaryReasoningEffort
            settings.codexModelID = "frozen-model"
            settings.codexReasoningEffort = "high"
            vaultSettings.summaryModelID = "frozen-model"
            vaultSettings.summaryReasoningEffort = "high"
            defer {
                settings.codexModelID = originalModel
                settings.codexReasoningEffort = originalEffort
                vaultSettings.summaryModelID = originalVaultModel
                vaultSettings.summaryReasoningEffort = originalVaultEffort
            }
            let viewModel = CaptionViewModel(
                summaryGenerationRunner: runner.run,
                summaryJobSleeper: sleeper.sleep
            )
            let options = SummaryGenerationOptions(
                exportOptions: SummaryExportOptions(exportsToVault: false, exportsToGoogleDocs: false),
                detailLevel: .eventSession
            )
            await fixture.select(fixture.first, in: viewModel, note: "note")

            viewModel.triggerManualSummary(options: options)
            await runner.waitForCallCount(1)
            settings.codexModelID = "changed-model"
            settings.codexReasoningEffort = "low"
            vaultSettings.summaryModelID = "changed-model"
            vaultSettings.summaryReasoningEffort = "low"
            #expect(runner.calls[0].settings.modelID == "frozen-model")
            #expect(runner.calls[0].settings.reasoningEffort == "high")
            #expect(runner.calls[0].settings.detailLevelInstruction == SummaryDetailLevel.eventSession.instruction)

            runner.fail(meetingID: fixture.first.id)
            #expect(await waitUntil { !viewModel.isSummaryGenerating(meetingId: fixture.first.id) })
            let failedJobID = try #require(viewModel.summaryGenerationJobs.first(where: \.hasFailure)?.id)

            viewModel.triggerManualSummary(options: options)
            await runner.waitForCallCount(2)
            #expect(viewModel.summaryGenerationJobs.contains { $0.id == failedJobID })
            #expect(viewModel.summaryGenerationJobs.count == 2)

            runner.complete(meetingID: fixture.first.id, title: "Recovered")
            #expect(await waitUntil { !viewModel.isSummaryGenerating(meetingId: fixture.first.id) })
            await sleeper.waitUntilSleeping()
            #expect(viewModel.summaryGenerationJobs.count == 2)
            await sleeper.resume()
            #expect(await waitUntil { viewModel.summaryGenerationJobs.count == 1 })
            #expect(viewModel.summaryGenerationJobs[0].id == failedJobID)

            viewModel.dismissSummaryGenerationJob(failedJobID)
            #expect(viewModel.summaryGenerationJobs.isEmpty)
        }

        @Test
        func pendingAutomaticSummaryKeepsItsSourceVaultProvider() async throws {
            let fixture = try SummaryGenerationFixture()
            defer { fixture.removeFiles() }
            let runner = BlockingSummaryRunner()
            let viewModel = CaptionViewModel(summaryGenerationRunner: runner.run)
            let options = SummaryGenerationOptions(
                exportOptions: SummaryExportOptions(exportsToVault: false, exportsToGoogleDocs: false)
            )
            let sessionID = UUID.v7()
            let sourceSettings = SummaryGenerationSettings(
                modelID: "source-model",
                reasoningEffort: "high",
                detailLevelInstruction: SummaryDetailLevel.concise.instruction,
                languageDisplayName: "Japanese",
                runtimeProvider: .dahlia(connectionID: UUID.v7())
            )
            viewModel.registerPendingBatchSummaryForTesting(
                sessionID: sessionID,
                meetingID: fixture.first.id,
                options: options,
                dbQueue: fixture.database.dbQueue,
                vaultURL: fixture.vaultURL,
                generationSettings: sourceSettings
            )

            await viewModel.handleBatchTranscriptionUpdate(.init(
                meetingId: fixture.first.id,
                state: .completed(sessionId: sessionID)
            ))
            await runner.waitForCallCount(1)

            #expect(runner.calls[0].settings.modelID == "source-model")
            #expect(runner.calls[0].settings.runtimeProvider == sourceSettings.runtimeProvider)
            runner.complete(meetingID: fixture.first.id, title: "Source summary")
            #expect(await waitUntil { !viewModel.isSummaryGenerating(meetingId: fixture.first.id) })
        }

        @Test
        func automaticRequestsWaitForTheirSessionsAndCoalesceAfterTheActiveJob() async throws {
            let fixture = try SummaryGenerationFixture()
            defer { fixture.removeFiles() }
            let runner = BlockingSummaryRunner()
            let viewModel = CaptionViewModel(summaryGenerationRunner: runner.run)
            let manualOptions = SummaryGenerationOptions(
                exportOptions: SummaryExportOptions(exportsToVault: false, exportsToGoogleDocs: false)
            )
            let eventOptions = SummaryGenerationOptions(
                exportOptions: SummaryExportOptions(exportsToVault: false, exportsToGoogleDocs: false),
                detailLevel: .eventSession
            )
            let conciseOptions = SummaryGenerationOptions(
                exportOptions: SummaryExportOptions(exportsToVault: false, exportsToGoogleDocs: false),
                detailLevel: .concise
            )
            await fixture.select(fixture.first, in: viewModel, note: "manual")
            viewModel.triggerManualSummary(options: manualOptions)
            await runner.waitForCallCount(1)
            await fixture.select(fixture.second, in: viewModel, note: "visible")

            let firstSessionID = try fixture.insertRecordingSession(for: fixture.first, offset: 0)
            let secondSessionID = UUID.v7()
            viewModel.registerPendingBatchSummaryForTesting(
                sessionID: firstSessionID,
                meetingID: fixture.first.id,
                options: eventOptions,
                dbQueue: fixture.database.dbQueue,
                vaultURL: fixture.vaultURL
            )
            viewModel.registerPendingBatchSummaryForTesting(
                sessionID: secondSessionID,
                meetingID: fixture.first.id,
                options: conciseOptions,
                dbQueue: fixture.database.dbQueue,
                vaultURL: fixture.vaultURL
            )
            await viewModel.handleBatchTranscriptionUpdate(.init(
                meetingId: fixture.first.id,
                state: .completed(sessionId: firstSessionID)
            ))
            #expect(runner.calls.count == 1)

            runner.complete(meetingID: fixture.first.id, title: "Manual")
            await runner.waitForCallCount(2)
            #expect(runner.calls[1].recordingSessionIDs == [firstSessionID])
            #expect(runner.calls[1].settings.detailLevelInstruction == SummaryDetailLevel.eventSession.instruction)

            _ = try fixture.insertRecordingSession(
                for: fixture.first,
                id: secondSessionID,
                offset: 60
            )
            await viewModel.handleBatchTranscriptionUpdate(.init(
                meetingId: fixture.first.id,
                state: .completed(sessionId: secondSessionID)
            ))
            #expect(runner.calls.count == 2)

            runner.complete(meetingID: fixture.first.id, title: "First automatic")
            await runner.waitForCallCount(3)
            #expect(Set(runner.calls[2].recordingSessionIDs) == [firstSessionID, secondSessionID])
            #expect(runner.calls[2].settings.detailLevelInstruction == SummaryDetailLevel.eventSession.instruction)
            runner.complete(meetingID: fixture.first.id, title: "Second automatic")
            #expect(await waitUntil { !viewModel.isSummaryGenerating(meetingId: fixture.first.id) })
            #expect(runner.calls.count == 3)
            #expect(viewModel.currentMeetingId == fixture.second.id)
            #expect(viewModel.currentSummaryDocument == nil)
        }

        @Test
        func pendingAutomaticRequestsKeepDifferentPersistenceContextsSeparate() async throws {
            let original = try SummaryGenerationFixture()
            let destination = try SummaryGenerationFixture()
            defer {
                original.removeFiles()
                destination.removeFiles()
            }
            try destination.insertMeeting(
                id: original.first.id,
                name: "Moved",
                transcript: "moved transcript"
            )
            let runner = BlockingSummaryRunner()
            let viewModel = CaptionViewModel(summaryGenerationRunner: runner.run)
            let options = SummaryGenerationOptions(
                exportOptions: SummaryExportOptions(exportsToVault: false, exportsToGoogleDocs: false)
            )
            let originalSessionID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
            let destinationSessionID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))

            await original.select(original.first, in: viewModel, note: "manual")
            viewModel.triggerManualSummary(options: options)
            await runner.waitForCallCount(1)

            viewModel.registerPendingBatchSummaryForTesting(
                sessionID: originalSessionID,
                meetingID: original.first.id,
                options: options,
                dbQueue: original.database.dbQueue,
                vaultURL: original.vaultURL
            )
            viewModel.registerPendingBatchSummaryForTesting(
                sessionID: destinationSessionID,
                meetingID: original.first.id,
                options: options,
                dbQueue: destination.database.dbQueue,
                vaultURL: destination.vaultURL
            )
            await viewModel.handleBatchTranscriptionUpdate(.init(
                meetingId: original.first.id,
                state: .completed(sessionId: originalSessionID)
            ))
            await viewModel.handleBatchTranscriptionUpdate(.init(
                meetingId: original.first.id,
                state: .completed(sessionId: destinationSessionID)
            ))

            runner.complete(meetingID: original.first.id, title: "Manual")
            await runner.waitForCallCount(2)
            runner.complete(meetingID: original.first.id, title: "Original context")
            await runner.waitForCallCount(3)

            #expect(try original.summary(for: original.first.id)?.loadDocument().title == "Original context")
            #expect(try destination.summary(for: original.first.id) == nil)

            runner.complete(meetingID: original.first.id, title: "Destination context")
            #expect(await waitUntil { !viewModel.isSummaryGenerating(meetingId: original.first.id) })
            #expect(try original.summary(for: original.first.id)?.loadDocument().title == "Original context")
            #expect(try destination.summary(for: original.first.id)?.loadDocument().title == "Destination context")
        }

        @Test
        func automaticOptionsFollowTheirPersistenceContextAcrossQueuedRequests() async throws {
            let original = try SummaryGenerationFixture()
            let destination = try SummaryGenerationFixture()
            defer {
                original.removeFiles()
                destination.removeFiles()
            }
            try destination.insertMeeting(
                id: original.first.id,
                name: "Moved",
                transcript: "moved transcript"
            )
            let destinationMeeting = try #require(
                try MeetingRepository(dbQueue: destination.database.dbQueue).fetchMeeting(id: original.first.id)
            )
            let runner = BlockingSummaryRunner()
            let viewModel = CaptionViewModel(summaryGenerationRunner: runner.run)
            let eventOptions = SummaryGenerationOptions(
                exportOptions: SummaryExportOptions(exportsToVault: true, exportsToGoogleDocs: false),
                detailLevel: .eventSession
            )
            let sameContextOptions = SummaryGenerationOptions(
                exportOptions: SummaryExportOptions(exportsToVault: false, exportsToGoogleDocs: true),
                detailLevel: .concise
            )
            let otherContextOptions = SummaryGenerationOptions(
                exportOptions: SummaryExportOptions(exportsToVault: false, exportsToGoogleDocs: false),
                detailLevel: .concise
            )
            let activeSessionID = try original.insertRecordingSession(for: original.first, offset: 0)
            viewModel.registerPendingBatchSummaryForTesting(
                sessionID: activeSessionID,
                meetingID: original.first.id,
                options: eventOptions,
                dbQueue: original.database.dbQueue,
                vaultURL: original.vaultURL
            )
            await viewModel.handleBatchTranscriptionUpdate(.init(
                meetingId: original.first.id,
                state: .completed(sessionId: activeSessionID)
            ))
            await runner.waitForCallCount(1)

            let otherContextSessionID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
            let sameContextSessionID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
            let otherMeetingSessionID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000003"))
            let failedSessionID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000004"))
            _ = try destination.insertRecordingSession(
                for: destinationMeeting,
                id: otherContextSessionID,
                offset: 0
            )
            _ = try original.insertRecordingSession(
                for: original.first,
                id: sameContextSessionID,
                offset: 60
            )
            _ = try original.insertRecordingSession(
                for: original.second,
                id: otherMeetingSessionID,
                offset: 0
            )
            _ = try original.insertRecordingSession(
                for: original.first,
                id: failedSessionID,
                offset: 90
            )
            viewModel.registerPendingBatchSummaryForTesting(
                sessionID: otherContextSessionID,
                meetingID: original.first.id,
                options: otherContextOptions,
                dbQueue: destination.database.dbQueue,
                vaultURL: destination.vaultURL
            )
            viewModel.registerPendingBatchSummaryForTesting(
                sessionID: sameContextSessionID,
                meetingID: original.first.id,
                options: sameContextOptions,
                dbQueue: original.database.dbQueue,
                vaultURL: original.vaultURL
            )
            viewModel.registerPendingBatchSummaryForTesting(
                sessionID: otherMeetingSessionID,
                meetingID: original.second.id,
                options: otherContextOptions,
                dbQueue: original.database.dbQueue,
                vaultURL: original.vaultURL
            )
            viewModel.registerPendingBatchSummaryForTesting(
                sessionID: failedSessionID,
                meetingID: original.first.id,
                options: otherContextOptions,
                dbQueue: original.database.dbQueue,
                vaultURL: original.vaultURL
            )
            let failedJobID = try #require(viewModel.summaryGenerationJobs.last?.id)
            await viewModel.handleBatchTranscriptionUpdate(.init(
                meetingId: original.first.id,
                state: .failed(sessionId: failedSessionID, message: "speech failed")
            ))
            await viewModel.handleBatchTranscriptionUpdate(.init(
                meetingId: original.first.id,
                state: .completed(sessionId: otherContextSessionID)
            ))

            runner.complete(meetingID: original.first.id, title: "First context")
            await runner.waitForCallCount(2)
            let failedJob = try #require(viewModel.summaryGenerationJobs.first { $0.id == failedJobID })
            #expect(failedJob.isFinished)
            #expect(failedJob.progress.vaultExport.isSkipped)
            #expect(failedJob.progress.googleDocsExport.isSkipped)
            #expect(runner.calls[1].settings.detailLevelInstruction == SummaryDetailLevel.concise.instruction)
            let otherContextJob = try #require(viewModel.summaryGenerationJobs.first {
                if case .running = $0.progress.summaryGeneration { true } else { false }
            })
            #expect(otherContextJob.progress.vaultExport.isSkipped)
            #expect(otherContextJob.progress.googleDocsExport.isSkipped)

            await viewModel.handleBatchTranscriptionUpdate(.init(
                meetingId: original.first.id,
                state: .completed(sessionId: sameContextSessionID)
            ))

            runner.fail(meetingID: original.first.id)
            await runner.waitForCallCount(3)
            #expect(runner.calls[2].settings.detailLevelInstruction == SummaryDetailLevel.eventSession.instruction)
            let sameContextJob = try #require(viewModel.summaryGenerationJobs.first {
                if case .running = $0.progress.summaryGeneration { true } else { false }
            })
            #expect(!sameContextJob.progress.vaultExport.isSkipped)
            #expect(!sameContextJob.progress.googleDocsExport.isSkipped)
            runner.fail(meetingID: original.first.id)
            #expect(await waitUntil { !viewModel.isSummaryGenerating(meetingId: original.first.id) })

            await viewModel.handleBatchTranscriptionUpdate(.init(
                meetingId: original.second.id,
                state: .completed(sessionId: otherMeetingSessionID)
            ))
            await runner.waitForCallCount(4)
            #expect(runner.calls[3].settings.detailLevelInstruction == SummaryDetailLevel.concise.instruction)
            let otherMeetingJob = try #require(viewModel.summaryGenerationJobs.first {
                if case .running = $0.progress.summaryGeneration { true } else { false }
            })
            #expect(otherMeetingJob.progress.vaultExport.isSkipped)
            #expect(otherMeetingJob.progress.googleDocsExport.isSkipped)
            runner.fail(meetingID: original.second.id)
            #expect(await waitUntil { !viewModel.isSummaryGenerating(meetingId: original.second.id) })
        }

        @Test
        func completedBatchWithoutSummaryRequestDoesNotRetainSessionID() async {
            let viewModel = CaptionViewModel()

            await viewModel.handleBatchTranscriptionUpdate(.init(
                meetingId: .v7(),
                state: .completed(sessionId: .v7())
            ))

            #expect(viewModel.completedBatchSummarySessionCountForTesting == 0)
        }

        @Test
        func automaticSummaryWaitsUntilScreenshotDeletionFinishes() async throws {
            let fixture = try SummaryGenerationFixture()
            defer { fixture.removeFiles() }
            let runner = BlockingSummaryRunner()
            let viewModel = CaptionViewModel(summaryGenerationRunner: runner.run)
            let sessionID = UUID.v7()
            let options = SummaryGenerationOptions(
                exportOptions: SummaryExportOptions(exportsToVault: false, exportsToGoogleDocs: false)
            )
            viewModel.registerPendingBatchSummaryForTesting(
                sessionID: sessionID,
                meetingID: fixture.first.id,
                options: options,
                dbQueue: fixture.database.dbQueue,
                vaultURL: fixture.vaultURL
            )
            viewModel.setScreenshotDeletionInProgressForTesting(true)

            await viewModel.handleBatchTranscriptionUpdate(.init(
                meetingId: fixture.first.id,
                state: .completed(sessionId: sessionID)
            ))

            #expect(runner.calls.isEmpty)
            #expect(viewModel.completedBatchSummarySessionCountForTesting == 1)

            viewModel.setScreenshotDeletionInProgressForTesting(false)
            await runner.waitForCallCount(1)
            runner.complete(meetingID: fixture.first.id, title: "After deletion")
            #expect(await waitUntil { !viewModel.isSummaryGenerating(meetingId: fixture.first.id) })
            #expect(try fixture.summary(for: fixture.first.id)?.loadDocument().title == "After deletion")
        }

        @Test
        func automaticSummaryPreservesMergedOptionsWhileScreenshotDeletionDefersNextRequest() async throws {
            let fixture = try SummaryGenerationFixture()
            defer { fixture.removeFiles() }
            let runner = BlockingSummaryRunner()
            let viewModel = CaptionViewModel(summaryGenerationRunner: runner.run)
            let firstSessionID = try fixture.insertRecordingSession(for: fixture.first, offset: 0)
            let secondSessionID = try fixture.insertRecordingSession(for: fixture.first, offset: 60)

            viewModel.registerPendingBatchSummaryForTesting(
                sessionID: firstSessionID,
                meetingID: fixture.first.id,
                options: SummaryGenerationOptions(
                    exportOptions: SummaryExportOptions(exportsToVault: true, exportsToGoogleDocs: false),
                    detailLevel: .eventSession
                ),
                dbQueue: fixture.database.dbQueue,
                vaultURL: fixture.vaultURL
            )
            await viewModel.handleBatchTranscriptionUpdate(.init(
                meetingId: fixture.first.id,
                state: .completed(sessionId: firstSessionID)
            ))
            await runner.waitForCallCount(1)

            viewModel.registerPendingBatchSummaryForTesting(
                sessionID: secondSessionID,
                meetingID: fixture.first.id,
                options: SummaryGenerationOptions(
                    exportOptions: SummaryExportOptions(exportsToVault: false, exportsToGoogleDocs: true),
                    detailLevel: .concise
                ),
                dbQueue: fixture.database.dbQueue,
                vaultURL: fixture.vaultURL
            )
            await viewModel.handleBatchTranscriptionUpdate(.init(
                meetingId: fixture.first.id,
                state: .completed(sessionId: secondSessionID)
            ))

            viewModel.setScreenshotDeletionInProgressForTesting(true)
            runner.complete(meetingID: fixture.first.id, title: "First automatic")
            #expect(await waitUntil { !viewModel.isSummaryGenerating(meetingId: fixture.first.id) })
            #expect(runner.calls.count == 1)

            viewModel.setScreenshotDeletionInProgressForTesting(false)
            await runner.waitForCallCount(2)
            #expect(runner.calls[1].settings.detailLevelInstruction == SummaryDetailLevel.eventSession.instruction)
            let job = try #require(viewModel.summaryGenerationJobs.first {
                if case .running = $0.progress.summaryGeneration { true } else { false }
            })
            #expect(!job.progress.vaultExport.isSkipped)
            #expect(!job.progress.googleDocsExport.isSkipped)
            runner.fail(meetingID: fixture.first.id)
            #expect(await waitUntil { !viewModel.isSummaryGenerating(meetingId: fixture.first.id) })
        }

        @Test
        func backgroundPreparationFailureCreatesDismissibleJob() async throws {
            let fixture = try SummaryGenerationFixture()
            defer { fixture.removeFiles() }
            let viewModel = CaptionViewModel()
            let missingMeetingID = UUID.v7()
            let sessionID = UUID.v7()
            viewModel.registerPendingBatchSummaryForTesting(
                sessionID: sessionID,
                meetingID: missingMeetingID,
                options: SummaryGenerationOptions(
                    exportOptions: SummaryExportOptions(exportsToVault: false, exportsToGoogleDocs: false)
                ),
                dbQueue: fixture.database.dbQueue,
                vaultURL: fixture.vaultURL
            )

            await viewModel.handleBatchTranscriptionUpdate(.init(
                meetingId: missingMeetingID,
                state: .completed(sessionId: sessionID)
            ))

            let failedJob = try #require(viewModel.summaryGenerationJobs.first)
            #expect(failedJob.meetingId == missingMeetingID)
            #expect(failedJob.hasFailure)
            #expect(failedJob.isFinished)
            viewModel.dismissSummaryGenerationJob(failedJob.id)
            #expect(viewModel.summaryGenerationJobs.isEmpty)
        }

        @Test
        func batchConfirmationKeepsOriginalDatabaseAndVaultAfterNavigation() async throws {
            let original = try SummaryGenerationFixture()
            let destination = try SummaryGenerationFixture()
            defer {
                original.removeFiles()
                destination.removeFiles()
            }
            let runner = BlockingSummaryRunner()
            let viewModel = CaptionViewModel(summaryGenerationRunner: runner.run)
            let project = try original.insertProject(name: "Original Project", description: "Original context")
            let options = SummaryGenerationOptions(
                exportOptions: SummaryExportOptions(exportsToVault: false, exportsToGoogleDocs: false)
            )
            await original.select(original.first, in: viewModel, note: "original")
            let sessionID = try original.insertRecordingSession(for: original.first, offset: 0)
            await viewModel.presentBatchTranscriptionConfirmation(
                sessionId: sessionID,
                meetingId: original.first.id,
                dbQueue: original.database.dbQueue
            )

            await destination.select(destination.first, in: viewModel, note: "destination")
            let confirmation = try #require(viewModel.pendingBatchTranscriptionConfirmation)
            let projectSelection = confirmation.projectSelection
            #expect(projectSelection.projects.map(\.id) == [project.id])
            #expect(projectSelection.selectedProjectId == nil)
            #expect(projectSelection.errorMessage == nil)

            #expect(viewModel.assignPendingBatchTranscriptionProject(.v7()) != nil)
            #expect(try original.projectId(for: original.first.id) == nil)
            #expect(viewModel.assignPendingBatchTranscriptionProject(project.id) == nil)
            #expect(try original.projectId(for: original.first.id) == project.id)
            #expect(viewModel.currentMeetingId == destination.first.id)
            #expect(viewModel.currentProjectId == nil)

            viewModel.confirmPendingBatchSummaryForTesting(
                sessionID: sessionID,
                meetingID: original.first.id,
                options: options
            )
            await viewModel.handleBatchTranscriptionUpdate(.init(
                meetingId: original.first.id,
                state: .completed(sessionId: sessionID)
            ))
            await runner.waitForCallCount(1)

            #expect(runner.calls[0].meetingID == original.first.id)
            #expect(runner.calls[0].projectName == project.path)
            #expect(runner.calls[0].projectDescription == project.description)
            runner.complete(meetingID: original.first.id, title: "Original summary")
            #expect(await waitUntil { !viewModel.isSummaryGenerating(meetingId: original.first.id) })
            #expect(try original.summary(for: original.first.id) != nil)
            #expect(try destination.summary(for: original.first.id) == nil)
            #expect(viewModel.currentMeetingId == destination.first.id)
            #expect(viewModel.currentSummaryDocument == nil)
        }

        private func waitUntil(
            attempts: Int = 10000,
            condition: @escaping @MainActor () -> Bool
        ) async -> Bool {
            for _ in 0 ..< attempts {
                if condition() { return true }
                await Task.yield()
            }
            return condition()
        }
    }

    @MainActor
    final class BlockingSummaryRunner {
        struct Call {
            let meetingID: UUID
            let recordedAt: Date
            let noteText: String?
            let projectName: String?
            let projectDescription: String?
            let settings: SummaryGenerationSettings
            let recordingSessionIDs: [UUID]
        }

        enum TestError: Error {
            case failed
        }

        private(set) var calls: [Call] = []
        private var continuations: [UUID: CheckedContinuation<Result<SummaryService.GeneratedSummary, Error>, Never>] = [:]
        private var callWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

        func run(_ input: SummaryGenerationRunnerInput) async throws -> SummaryService.GeneratedSummary {
            calls.append(Call(
                meetingID: input.promptContext.meetingId,
                recordedAt: input.promptContext.recordedAt,
                noteText: input.noteText,
                projectName: input.promptContext.projectName,
                projectDescription: input.promptContext.projectDescription,
                settings: input.generationSettings,
                recordingSessionIDs: input.recordingSessions.map(\.id)
            ))
            resumeCallWaiters()
            let result = await withCheckedContinuation { continuation in
                continuations[input.promptContext.meetingId] = continuation
            }
            return try result.get()
        }

        func waitForCallCount(_ count: Int) async {
            if calls.count >= count { return }
            await withCheckedContinuation { continuation in
                callWaiters.append((count, continuation))
            }
        }

        func complete(meetingID: UUID, title: String) {
            continuations.removeValue(forKey: meetingID)?.resume(returning: .success(.init(
                document: SummaryDocument(title: title, sections: []),
                fileName: "summary.md",
                markdown: title
            )))
        }

        func fail(meetingID: UUID) {
            continuations.removeValue(forKey: meetingID)?.resume(returning: .failure(TestError.failed))
        }

        private func resumeCallWaiters() {
            let ready = callWaiters.filter { calls.count >= $0.count }
            callWaiters.removeAll { calls.count >= $0.count }
            ready.forEach { $0.continuation.resume() }
        }
    }

    @MainActor
    private final class BlockingSummaryDocumentLoader {
        private var continuation: CheckedContinuation<SummaryDocument?, Never>?
        private var callWaiter: CheckedContinuation<Void, Never>?

        func load(_: UUID, _: DatabaseQueue) async throws -> SummaryDocument? {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                callWaiter?.resume()
                callWaiter = nil
            }
        }

        func waitForCall() async {
            if continuation != nil { return }
            await withCheckedContinuation { callWaiter = $0 }
        }

        func complete(document: SummaryDocument?) {
            continuation?.resume(returning: document)
            continuation = nil
        }
    }

    @MainActor
    private final class BlockingGoogleDocsSummaryExporter {
        private var continuation: CheckedContinuation<String, Never>?
        private var callWaiter: CheckedContinuation<Void, Never>?

        func export(_: SummaryDocument, _: SummaryRenderContext, _: String) async throws -> String {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                callWaiter?.resume()
                callWaiter = nil
            }
        }

        func waitForCall() async {
            if continuation != nil { return }
            await withCheckedContinuation { callWaiter = $0 }
        }

        func complete(fileId: String) {
            continuation?.resume(returning: fileId)
            continuation = nil
        }
    }

    private actor BlockingArtifactSummaryExporter {
        private var continuation: CheckedContinuation<DahliaArtifactExportResult, Never>?
        private var callWaiter: CheckedContinuation<Void, Never>?

        func export(_: String, _: UUID, _: String, _: URL?) async throws -> DahliaArtifactExportResult {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                callWaiter?.resume()
                callWaiter = nil
            }
        }

        func waitForCall() async {
            if continuation != nil { return }
            await withCheckedContinuation { callWaiter = $0 }
        }

        func complete(result: DahliaArtifactExportResult) {
            continuation?.resume(returning: result)
            continuation = nil
        }
    }

    private actor ArtifactDeleteRecorder {
        private(set) var deletedURLs: [URL] = []

        func delete(url: URL, connectionID _: UUID, origin _: String) {
            deletedURLs.append(url)
        }
    }

    private actor ControlledSummaryJobSleeper {
        private var continuation: CheckedContinuation<Void, Never>?
        private var waiter: CheckedContinuation<Void, Never>?

        func sleep(for _: Duration) async throws {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                waiter?.resume()
                waiter = nil
            }
        }

        func waitUntilSleeping() async {
            if continuation != nil { return }
            await withCheckedContinuation { waiter = $0 }
        }

        func resume() {
            continuation?.resume()
            continuation = nil
        }
    }

    @MainActor
    final class SummaryGenerationFixture {
        let database: AppDatabaseManager
        let vault: VaultRecord
        let vaultURL: URL
        let first: MeetingRecord
        let second: MeetingRecord

        init() throws {
            database = try AppDatabaseManager(path: ":memory:")
            vaultURL = FileManager.default.temporaryDirectory
                .appending(path: "dahlia-summary-vm-\(UUID.v7())", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)
            let now = Date(timeIntervalSince1970: 1_776_384_000)
            vault = VaultRecord(id: .v7(), path: vaultURL.path, name: "Test", createdAt: now, lastOpenedAt: now)
            first = MeetingRecord(
                id: .v7(), vaultId: vault.id, projectId: nil, name: "First", createdAt: now, updatedAt: now
            )
            second = MeetingRecord(
                id: .v7(),
                vaultId: vault.id,
                projectId: nil,
                name: "Second",
                createdAt: now.addingTimeInterval(60),
                updatedAt: now.addingTimeInterval(60)
            )
            let firstSegment = TranscriptSegment(
                startTime: now, text: "first transcript", isConfirmed: true, speakerLabel: "mic"
            )
            let secondSegment = TranscriptSegment(
                startTime: now.addingTimeInterval(60), text: "second transcript", isConfirmed: true, speakerLabel: "mic"
            )
            try database.dbQueue.write { db in
                try vault.insert(db)
                try first.insert(db)
                try second.insert(db)
                try TranscriptSegmentRecord(from: firstSegment, meetingId: first.id).insert(db)
                try TranscriptSegmentRecord(from: secondSegment, meetingId: second.id).insert(db)
            }
        }

        func select(_ meeting: MeetingRecord, in viewModel: CaptionViewModel, note: String) async {
            viewModel.loadMeeting(
                meeting.id,
                dbQueue: database.dbQueue,
                projectURL: nil,
                projectId: nil,
                vaultURL: vaultURL
            )
            _ = await pollUntil {
                viewModel.currentMeetingId == meeting.id
                    && viewModel.currentMeetingHasTranscriptSegments
            }
            viewModel.noteText = note
        }

        func summary(for meetingID: UUID) throws -> SummaryRecord? {
            try database.dbQueue.read { db in
                try SummaryRecord.fetchOne(db, key: meetingID)
            }
        }

        func summaryPath(for meetingID: UUID) throws -> String? {
            try database.dbQueue.read { db in
                try SummaryExportRecord.fetchOne(
                    meetingId: meetingID,
                    type: .vault,
                    in: db
                )?.vaultRelativePath
            }
        }

        func projectId(for meetingID: UUID) throws -> UUID? {
            try database.dbQueue.read { db in
                try MeetingRecord.fetchOne(db, key: meetingID)?.projectId
            }
        }

        func insertProject(name: String, description: String) throws -> ProjectRecord {
            let projectURL = vaultURL.appending(path: name, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
            let project = ProjectRecord(
                id: .v7(),
                vaultId: vault.id,
                path: name,
                createdAt: first.createdAt,
                description: description
            )
            try database.dbQueue.write { db in try project.insert(db) }
            return project
        }

        func assign(_ meeting: MeetingRecord, to project: ProjectRecord) throws {
            _ = try database.dbQueue.write { db in
                try MeetingRecord
                    .filter(key: meeting.id)
                    .updateAll(db, Column("projectId").set(to: project.id))
            }
        }

        func insertRecordingSession(
            for meeting: MeetingRecord,
            id: UUID = .v7(),
            offset: TimeInterval
        ) throws -> UUID {
            let startedAt = meeting.createdAt.addingTimeInterval(offset)
            let session = RecordingSessionRecord(
                id: id,
                meetingId: meeting.id,
                startedAt: startedAt,
                endedAt: startedAt.addingTimeInterval(30),
                duration: 30,
                offsetSeconds: offset,
                createdAt: startedAt,
                updatedAt: startedAt,
                transcriptionMode: .batch,
                batchCompletedAt: startedAt.addingTimeInterval(30)
            )
            try database.dbQueue.write { db in try session.insert(db) }
            return id
        }

        func insertMeeting(id: UUID, name: String, transcript: String) throws {
            let createdAt = Date(timeIntervalSince1970: 1_776_384_120)
            let meeting = MeetingRecord(
                id: id,
                vaultId: vault.id,
                projectId: nil,
                name: name,
                createdAt: createdAt,
                updatedAt: createdAt
            )
            let segment = TranscriptSegment(
                startTime: createdAt,
                text: transcript,
                isConfirmed: true,
                speakerLabel: "mic"
            )
            try database.dbQueue.write { db in
                try meeting.insert(db)
                try TranscriptSegmentRecord(from: segment, meetingId: id).insert(db)
            }
        }

        func removeFiles() {
            try? FileManager.default.removeItem(at: vaultURL)
        }
    }
#endif
