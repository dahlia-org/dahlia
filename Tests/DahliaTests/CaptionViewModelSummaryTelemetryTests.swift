import GRDB
@testable import Dahlia
@testable import DahliaRuntimeSupport

#if canImport(Testing)
    import Testing

    @MainActor
    @Suite(.serialized)
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
                exportOptions: .init(exportsToVault: false, exportsToGoogleDocs: false)
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
        func vaultExportAndFallbackPersistenceFailureStillEmitExportTerminal() async throws {
            let fixture = try SummaryGenerationFixture()
            defer { fixture.removeFiles() }
            let runner = BlockingSummaryRunner()
            var events: [UsageTelemetryEvent] = []
            let viewModel = CaptionViewModel(
                summaryGenerationRunner: runner.run,
                usageTelemetryReporter: { events.append($0) }
            )
            let options = SummaryGenerationOptions(
                exportOptions: .init(exportsToVault: true, exportsToGoogleDocs: false)
            )

            await fixture.select(fixture.first, in: viewModel, note: "note")
            #expect(await waitUntil { viewModel.canGenerateSummary })
            #expect(viewModel.triggerManualSummary(options: options))
            await runner.waitForCallCount(1)
            try await fixture.database.dbQueue.write { db in
                try db.execute(sql: "DROP TABLE summaries")
            }
            runner.complete(meetingID: fixture.first.id, title: "Generated")
            #expect(await waitUntil { !viewModel.isSummaryGenerating(meetingId: fixture.first.id) })

            #expect(events == [
                .summary(.started, trigger: .manual),
                .export(.started, destination: .vault, trigger: .summaryGeneration),
                .export(.failed(.export), destination: .vault, trigger: .summaryGeneration),
                .summary(.failed(.generation), trigger: .manual),
            ])
        }

        private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
            for _ in 0 ..< 10000 {
                if condition() { return true }
                await Task.yield()
            }
            return condition()
        }
    }
#endif
