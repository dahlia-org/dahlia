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
        func resetRestoresGoogleDocsExportToPending() {
            let state = SummaryProgressState()
            state.googleDocsExport = .failed("offline")

            state.reset()

            #expect(!state.googleDocsExport.isTerminal)
        }

        @Test
        func delayedDismissDoesNotHideNewerProgress() {
            let state = SummaryProgressState()
            let firstPresentationID = state.show()
            let secondPresentationID = state.show()

            state.dismiss(ifCurrent: firstPresentationID)

            #expect(state.isVisible)

            state.dismiss(ifCurrent: secondPresentationID)

            #expect(!state.isVisible)
        }
    }
#endif
