import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct SummaryProgressStateTests {
        @Test
        func waitsForWorkspaceExportToReachTerminalState() {
            let state = SummaryProgressState()
            state.summaryGeneration = .completed
            state.workspaceExport = .running

            #expect(!state.isAllDone)

            state.workspaceExport = .completed

            #expect(state.isAllDone)
        }

        @Test
        func generationJobsKeepMeetingProgressAndFailuresIndependent() {
            let first = SummaryGenerationJob(meetingId: .v7(), meetingName: "Planning")
            let second = SummaryGenerationJob(meetingId: .v7(), meetingName: "Review")

            first.progress.summaryGeneration = .failed("offline")
            first.progress.workspaceExport = .failed("offline")
            second.progress.summaryGeneration = .running

            #expect(first.hasFailure)
            #expect(first.isFinished)
            #expect(first.progress.summaryGeneration.failureMessage == "offline")
            #expect(first.progress.workspaceExport.failureMessage == "offline")
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
            job.progress.workspaceExport = .skipped

            #expect(!job.isFinished)

            job.progress.transcription = .completed

            #expect(job.isFinished)
        }

        @Test
        func localAutomaticRetranscriptionRequiresLanguageCandidates() {
            #expect(BatchTranscriptionConfirmationView.startDisabled(
                processingMethod: nil,
                languageSelection: .automatic,
                automaticLanguageLocales: []
            ))
            #expect(!BatchTranscriptionConfirmationView.startDisabled(
                processingMethod: .cloudTranscription,
                languageSelection: .recorded,
                automaticLanguageLocales: []
            ))
            #expect(BatchTranscriptionConfirmationView.startDisabled(
                processingMethod: .cloudTranscription,
                languageSelection: .recorded,
                automaticLanguageLocales: [],
                serverRetranscriptionUnavailable: true
            ))
        }
    }
#endif
