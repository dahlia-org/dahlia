import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    @Suite(.serialized)
    struct CaptionViewModelSummaryGenerationTests {
        @Test
        func manualSummaryUsesProjectSelectedBeforeGeneration() async throws {
            let fixture = try SummaryGenerationFixture()
            defer { fixture.removeFiles() }
            let runner = BlockingSummaryRunner()
            let viewModel = CaptionViewModel(summaryGenerationRunner: runner.run)
            let project = try fixture.insertProject(name: "Selected", description: "Selected context")
            try fixture.assign(fixture.first, to: project)
            let options = SummaryGenerationOptions(
                previousMeetingCount: 0,
                exportOptions: SummaryExportOptions(exportsToVault: false, exportsToGoogleDocs: false)
            )

            await fixture.select(fixture.first, in: viewModel, note: "note")
            viewModel.setExplicitProjectContext(
                projectURL: fixture.vaultURL.appending(path: project.name, directoryHint: .isDirectory),
                projectId: project.id,
                projectName: project.name
            )
            viewModel.triggerManualSummary(options: options)
            await runner.waitForCallCount(1)

            #expect(runner.calls[0].projectName == project.name)
            #expect(runner.calls[0].projectDescription == "Selected context")
            runner.complete(meetingID: fixture.first.id, title: "Summary")
            #expect(await waitUntil { !viewModel.isSummaryGenerating(meetingId: fixture.first.id) })
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
                previousMeetingCount: 0,
                exportOptions: SummaryExportOptions(exportsToVault: false, exportsToGoogleDocs: false)
            )

            viewModel.registerPendingBatchSummaryForTesting(
                sessionID: sessionID,
                meetingID: fixture.first.id,
                options: options,
                dbQueue: fixture.database.dbQueue,
                vaultURL: fixture.vaultURL
            )
            await viewModel.handleBatchTranscriptionUpdate(.init(
                meetingId: fixture.first.id,
                state: .completed(sessionId: sessionID)
            ))
            await runner.waitForCallCount(1)

            #expect(runner.calls[0].projectName == project.name)
            #expect(runner.calls[0].projectDescription == "Batch context")
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
                previousMeetingCount: 0,
                exportOptions: SummaryExportOptions(exportsToVault: false, exportsToGoogleDocs: false)
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
                previousMeetingCount: 0,
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
                previousMeetingCount: 0,
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
            let originalModel = settings.codexModelID
            let originalEffort = settings.codexReasoningEffort
            settings.codexModelID = "frozen-model"
            settings.codexReasoningEffort = "high"
            defer {
                settings.codexModelID = originalModel
                settings.codexReasoningEffort = originalEffort
            }
            let viewModel = CaptionViewModel(
                summaryGenerationRunner: runner.run,
                summaryJobSleeper: sleeper.sleep
            )
            let options = SummaryGenerationOptions(
                previousMeetingCount: 0,
                exportOptions: SummaryExportOptions(exportsToVault: false, exportsToGoogleDocs: false)
            )
            await fixture.select(fixture.first, in: viewModel, note: "note")

            viewModel.triggerManualSummary(options: options)
            await runner.waitForCallCount(1)
            settings.codexModelID = "changed-model"
            settings.codexReasoningEffort = "low"
            #expect(runner.calls[0].settings.modelID == "frozen-model")
            #expect(runner.calls[0].settings.reasoningEffort == "high")

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
        func automaticRequestsWaitForTheirSessionsAndCoalesceAfterTheActiveJob() async throws {
            let fixture = try SummaryGenerationFixture()
            defer { fixture.removeFiles() }
            let runner = BlockingSummaryRunner()
            let viewModel = CaptionViewModel(summaryGenerationRunner: runner.run)
            let options = SummaryGenerationOptions(
                previousMeetingCount: 0,
                exportOptions: SummaryExportOptions(exportsToVault: false, exportsToGoogleDocs: false)
            )
            await fixture.select(fixture.first, in: viewModel, note: "manual")
            viewModel.triggerManualSummary(options: options)
            await runner.waitForCallCount(1)
            await fixture.select(fixture.second, in: viewModel, note: "visible")

            let firstSessionID = try fixture.insertRecordingSession(for: fixture.first, offset: 0)
            let secondSessionID = UUID.v7()
            viewModel.registerPendingBatchSummaryForTesting(
                sessionID: firstSessionID,
                meetingID: fixture.first.id,
                options: options,
                dbQueue: fixture.database.dbQueue,
                vaultURL: fixture.vaultURL
            )
            viewModel.registerPendingBatchSummaryForTesting(
                sessionID: secondSessionID,
                meetingID: fixture.first.id,
                options: options,
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
                previousMeetingCount: 0,
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
                previousMeetingCount: 0,
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
                    previousMeetingCount: 0,
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
                previousMeetingCount: 0,
                exportOptions: SummaryExportOptions(exportsToVault: false, exportsToGoogleDocs: false)
            )
            await original.select(original.first, in: viewModel, note: "original")
            let sessionID = try original.insertRecordingSession(for: original.first, offset: 0)
            viewModel.presentBatchTranscriptionConfirmation(
                sessionId: sessionID,
                meetingId: original.first.id,
                dbQueue: original.database.dbQueue
            )

            await destination.select(destination.first, in: viewModel, note: "destination")
            let confirmation = try #require(viewModel.pendingBatchTranscriptionConfirmation)
            let projectSelection = viewModel.batchTranscriptionProjectSelection(for: confirmation)
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
            #expect(runner.calls[0].projectName == project.name)
            #expect(runner.calls[0].projectDescription == project.description)
            runner.complete(meetingID: original.first.id, title: "Original summary")
            #expect(await waitUntil { !viewModel.isSummaryGenerating(meetingId: original.first.id) })
            #expect(try original.summary(for: original.first.id) != nil)
            #expect(try destination.summary(for: original.first.id) == nil)
            #expect(viewModel.currentMeetingId == destination.first.id)
            #expect(viewModel.currentSummaryDocument == nil)
        }

        private func waitUntil(
            attempts: Int = 200,
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
    private final class BlockingSummaryRunner {
        struct Call {
            let meetingID: UUID
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
    private final class SummaryGenerationFixture {
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
            for _ in 0 ..< 200 {
                if viewModel.currentMeetingId == meeting.id,
                   viewModel.currentMeetingHasTranscriptSegments { break }
                await Task.yield()
            }
            viewModel.noteText = note
        }

        func summary(for meetingID: UUID) throws -> SummaryRecord? {
            try database.dbQueue.read { db in
                try SummaryRecord.fetchOne(db, key: meetingID)
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
                name: name,
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
                retainAudioAfterBatch: false,
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
