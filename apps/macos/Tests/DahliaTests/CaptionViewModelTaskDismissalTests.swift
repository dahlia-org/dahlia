import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct CaptionViewModelTaskDismissalTests {
        @Test(arguments: [false, true])
        func dismissedCancellationStaysHiddenAfterRestart(transcriptionOnly: Bool) async throws {
            let fixture = try SummaryGenerationFixture()
            defer { fixture.removeFiles() }
            let sessionID = try fixture.insertRecordingSession(for: fixture.first, offset: 0)
            let processing = RecordingProcessing(
                id: .v7(), automatic: true, liveDraft: false, localeIdentifier: "en_US", method: .transcript,
                options: .manual, generationSettings: .current(), workspaceSettings: nil,
                sessionIDs: [sessionID], stage: .cancelled, transcriptionOnly: transcriptionOnly
            )
            try await fixture.database.dbQueue.write { db in try processing.save(sessionID: sessionID, in: db) }
            let viewModel = CaptionViewModel()
            try await viewModel.restoreRecordingProcessingForTesting(dbQueue: fixture.database.dbQueue)
            let job = try #require(viewModel.summaryGenerationJobs.first)
            #expect(job.isCancelled)
            #expect(!job.hasFailure)
            viewModel.dismissSummaryGenerationJob(job.id)
            try #require(await pollUntil { viewModel.summaryGenerationJobs.isEmpty })

            let restarted = CaptionViewModel()
            try await restarted.restoreRecordingProcessingForTesting(dbQueue: fixture.database.dbQueue)
            #expect(restarted.summaryGenerationJobs.isEmpty)
            var saved = try #require(try await fixture.database.dbQueue.read { db in
                try RecordingProcessing.load(sessionID: sessionID, in: db)
            })
            #expect(saved.stage == .cancelled)
            #expect(saved.failureDismissed == true)
            #expect(try await fixture.database.dbQueue.read { db in
                try TranscriptSegmentBodyRecord.fetchAll(db).map(\.text).sorted()
            } == ["first transcript", "second transcript"])
            saved.prepareRetry()
            #expect(saved.failureDismissed == nil)
        }
    }
#endif
