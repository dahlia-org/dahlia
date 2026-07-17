@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct ApplicationLogViewModelTests {
        @Test
        func textReturnsAllLogsWhenSearchIsEmpty() {
            let model = ApplicationLogViewModel(logLines: ["first", "second"])

            #expect(model.text(matching: "") == "first\nsecond")
        }

        @Test
        func textFiltersLogsUsingLocalizedSearch() {
            let model = ApplicationLogViewModel(logLines: [
                "[NOTICE] Recording stopped",
                "[INFO] Capture started",
            ])

            #expect(model.text(matching: "recording") == "[NOTICE] Recording stopped")
            #expect(model.text(matching: "missing").isEmpty)
        }
    }
#endif
