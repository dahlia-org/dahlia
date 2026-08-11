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

        @Test
        func refreshUpdatesOnlyWhenSnapshotChanges() async {
            let loader = ApplicationLogLoaderStub(responses: [
                .success(["first"]),
                .success(["first"]),
                .success(["first", "second"]),
            ])
            let model = ApplicationLogViewModel(loadLogs: { try await loader.load() })

            await model.refresh()
            #expect(model.logLines == ["first"])
            #expect(model.revision == 1)

            await model.refresh()
            #expect(model.revision == 1)

            await model.refresh()
            #expect(model.logLines == ["first", "second"])
            #expect(model.revision == 2)
        }

        @Test
        func refreshPreservesLogsAcrossTransientFailure() async {
            let loader = ApplicationLogLoaderStub(responses: [
                .success(["first"]),
                .failure(.unavailable),
                .success(["first", "recovered"]),
            ])
            let model = ApplicationLogViewModel(loadLogs: { try await loader.load() })

            await model.refresh()
            await model.refresh()
            #expect(model.logLines == ["first"])
            #expect(model.errorMessage != nil)

            await model.refresh()
            #expect(model.logLines == ["first", "recovered"])
            #expect(model.errorMessage == nil)
        }

        @Test
        func refreshKeepsNewestTwoThousandLines() async {
            let lines = (0 ..< 2_100).map(String.init)
            let loader = ApplicationLogLoaderStub(responses: [.success(lines)])
            let model = ApplicationLogViewModel(loadLogs: { try await loader.load() })

            await model.refresh()

            #expect(model.logLines.count == 2_000)
            #expect(model.logLines.first == "100")
            #expect(model.logLines.last == "2099")
        }

        @Test
        func monitorStopsWhenPollingSleepIsCancelled() async {
            let loader = ApplicationLogLoaderStub(responses: [
                .success(["first"]),
                .success(["first", "second"]),
                .success(["unexpected"]),
            ])
            let sleeper = ApplicationLogSleeperStub(successfulSleepCount: 1)
            let model = ApplicationLogViewModel(
                loadLogs: { try await loader.load() },
                sleep: { try await sleeper.sleep(for: $0) }
            )

            await model.monitor()

            #expect(model.logLines == ["first", "second"])
            #expect(await loader.callCount == 2)
        }
    }
#endif
