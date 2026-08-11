@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct SummaryProgressStateTests {
        @Test
        func waitsForGoogleDocsExportToReachTerminalState() {
            let state = SummaryProgressState()
            state.summaryGeneration = .completed
            state.vaultExport = .skipped

            #expect(!state.isAllDone)

            state.googleDocsExport = .completed

            #expect(state.isAllDone)
        }

        @Test
        func generationJobsKeepMeetingProgressAndFailuresIndependent() {
            let first = SummaryGenerationJob(meetingId: .v7(), meetingName: "Planning")
            let second = SummaryGenerationJob(meetingId: .v7(), meetingName: "Review")

            first.progress.summaryGeneration = .failed("offline")
            first.progress.vaultExport = .failed("offline")
            first.progress.googleDocsExport = .failed("offline")
            second.progress.summaryGeneration = .running

            #expect(first.hasFailure)
            #expect(first.isFinished)
            #expect(first.progress.summaryGeneration.failureMessage == "offline")
            #expect(first.progress.vaultExport.failureMessage == "offline")
            #expect(first.progress.googleDocsExport.failureMessage == "offline")
            #expect(!second.hasFailure)
            #expect(second.progress.summaryGeneration.failureMessage == nil)
        }

        @Test
        func batchSummaryJobIncludesTranscriptionUntilItCompletes() {
            let job = SummaryGenerationJob(
                meetingId: .v7(),
                meetingName: "Planning",
                includesTranscription: true
            )
            job.progress.summaryGeneration = .completed
            job.progress.vaultExport = .skipped
            job.progress.googleDocsExport = .skipped

            #expect(!job.isFinished)

            job.progress.transcription = .completed

            #expect(job.isFinished)
        }
    }
#endif
