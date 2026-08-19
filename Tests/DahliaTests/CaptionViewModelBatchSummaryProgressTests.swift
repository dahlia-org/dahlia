import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    @Suite(.serialized)
    struct CaptionViewModelBatchSummaryProgressTests {
        @Test
        func failedBatchTranscriptionFinishesItsRunningTask() async throws {
            let fixture = try SummaryGenerationFixture()
            defer { fixture.removeFiles() }
            let viewModel = CaptionViewModel()
            let sessionID = UUID.v7()
            viewModel.registerPendingBatchSummaryForTesting(
                sessionID: sessionID,
                meetingID: fixture.first.id,
                options: .manual,
                dbQueue: fixture.database.dbQueue,
                vaultURL: fixture.vaultURL
            )

            await viewModel.handleBatchTranscriptionUpdate(.init(
                meetingId: fixture.first.id,
                state: .failed(sessionId: sessionID, message: "speech failed")
            ))

            let job = try #require(viewModel.summaryGenerationJobs.first)
            #expect(job.progress.transcription.failureMessage == "speech failed")
            #expect(job.progress.summaryGeneration.isSkipped)
            #expect(job.isFinished)
        }

        @Test
        func batchSummaryTracksEveryConfirmedSessionAndPreservesAnEarlierFailure() async throws {
            let fixture = try SummaryGenerationFixture()
            defer { fixture.removeFiles() }
            let runner = BlockingSummaryRunner()
            let viewModel = CaptionViewModel(summaryGenerationRunner: runner.run)
            let firstSessionID = UUID.v7()
            let secondSessionID = UUID.v7()
            viewModel.registerPendingBatchSummaryForTesting(
                sessionID: secondSessionID,
                meetingID: fixture.first.id,
                options: .manual,
                dbQueue: fixture.database.dbQueue,
                vaultURL: fixture.vaultURL
            )
            viewModel.registerConfirmedBatchSummarySessionsForTesting(
                anchorSessionID: secondSessionID,
                sessionIDs: [firstSessionID, secondSessionID]
            )
            let job = try #require(viewModel.summaryGenerationJobs.first)

            await viewModel.handleBatchTranscriptionUpdate(.init(
                meetingId: fixture.first.id,
                state: .running(
                    sessionId: firstSessionID,
                    progress: BatchTranscriptionProgress(completedFileCount: 1, totalFileCount: 2)
                )
            ))
            #expect(job.progress.transcriptionProgress == 0.25)

            await viewModel.handleBatchTranscriptionUpdate(.init(
                meetingId: fixture.first.id,
                state: .failed(sessionId: firstSessionID, message: "first failed")
            ))
            await viewModel.handleBatchTranscriptionUpdate(.init(
                meetingId: fixture.first.id,
                state: .completed(sessionId: secondSessionID)
            ))

            #expect(job.progress.transcription.failureMessage == "first failed")
            #expect(job.isFinished)
            #expect(runner.calls.isEmpty)
        }

        @Test
        func batchSummaryWaitsForEveryConfirmedSession() async throws {
            let fixture = try SummaryGenerationFixture()
            defer { fixture.removeFiles() }
            let runner = BlockingSummaryRunner()
            let viewModel = CaptionViewModel(summaryGenerationRunner: runner.run)
            let firstSessionID = UUID.v7()
            let secondSessionID = UUID.v7()
            viewModel.registerPendingBatchSummaryForTesting(
                sessionID: secondSessionID,
                meetingID: fixture.first.id,
                options: .manual,
                dbQueue: fixture.database.dbQueue,
                vaultURL: fixture.vaultURL
            )
            viewModel.registerConfirmedBatchSummarySessionsForTesting(
                anchorSessionID: secondSessionID,
                sessionIDs: [firstSessionID, secondSessionID]
            )
            let job = try #require(viewModel.summaryGenerationJobs.first)

            await viewModel.handleBatchTranscriptionUpdate(.init(
                meetingId: fixture.first.id,
                state: .completed(sessionId: firstSessionID)
            ))
            #expect(job.progress.transcriptionProgress == 0.5)
            #expect(runner.calls.isEmpty)

            await viewModel.handleBatchTranscriptionUpdate(.init(
                meetingId: fixture.first.id,
                state: .running(
                    sessionId: secondSessionID,
                    progress: BatchTranscriptionProgress(completedFileCount: 1, totalFileCount: 2)
                )
            ))
            #expect(job.progress.transcriptionProgress == 0.75)
            #expect(runner.calls.isEmpty)

            await viewModel.handleBatchTranscriptionUpdate(.init(
                meetingId: fixture.first.id,
                state: .completed(sessionId: secondSessionID)
            ))
            await runner.waitForCallCount(1)

            #expect(job.progress.transcription.isTerminal)
            #expect(!job.progress.transcription.isFailed)
            #expect(!job.progress.transcription.isSkipped)
            #expect(job.progress.transcriptionProgress == nil)
            runner.complete(meetingID: fixture.first.id, title: "Summary")
            #expect(await waitUntil { !viewModel.isSummaryGenerating(meetingId: fixture.first.id) })
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
#endif
