import DahliaMeetingAccess
import DahliaRuntimeSupport
import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct SummaryGenerationValidationTests {
        @Test(arguments: [true, false], [true, false])
        func incompleteOrUnavailableSummaryUsesFallbackAndRecordsTheActualModel(primaryValid: Bool, primaryAvailable: Bool) async throws {
            let valid = #"{"title":"Complete","sections":[{"heading":"Decisions","blocks":[{"type":"paragraph","content":{"text":"Ship next week"}}]}]}"#
            let incomplete = #"""
            {"title":"Incomplete","sections":[{"heading":"","blocks":[{"type":"image","image_id":"unknown","content":{"text":"A chart"}}]}],"action_items":[{"title":"Send notes"}]}
            """#
            let provider = CodexRuntimeContextStore.shared.provider
            let log = TestPiTransportLog()
            let pi = TestPiRuntime.generating(
                provider: provider,
                models: (["unrelated", "fallback"] + (primaryAvailable ? ["primary"] : [])).map { TestPiTransport.model(provider: "openai", id: $0) },
                replyForModel: { model in model == "openai/primary" && !primaryValid ? incomplete : valid },
                log: log
            )
            var preferences = WorkspaceGenerationSettings()
            preferences.local.fallbackModel = "openai/fallback"
            let settings = SummaryGenerationSettings(
                modelID: "openai/primary", reasoningEffort: "medium", detailLevelInstruction: "Detailed",
                languageDisplayName: "English", runtimeProvider: provider, workspacePreferences: preferences
            )

            let result = try await SummaryService.generateSummary(
                promptContext: .init(meetingId: .v7(), recordedAt: .now, calendarEvent: nil, projectName: nil, projectDescription: nil),
                transcriptText: "We decided to ship next week.", generationSettings: settings, appServer: pi.service
            )

            #expect(result.document.title == "Complete")
            #expect(result.document.metadata?.request.model == (primaryValid && primaryAvailable ? "openai/primary" : "openai/fallback"))
            #expect(pi.launches.all.count(where: { $0.mode == .summary }) == (!primaryValid && primaryAvailable ? 2 : 1))
            if !primaryValid, primaryAvailable {
                let transports = log.all
                try #require(transports.count == 3)
                let first = await transports[1].command("prompt")
                let second = await transports[2].command("prompt")
                #expect(first["message"] == second["message"])
            }
        }

        @Test
        func incompleteSummaryFailsWithoutReplacingSavedSummaryOrRetrying() async throws {
            let fixture = try SummaryGenerationFixture()
            defer { fixture.removeFiles() }
            let original = SummaryDocument(
                title: "Saved summary",
                sections: [.init(id: .v7(), heading: "Decisions", blocks: [.paragraph("Keep this decision")])]
            )
            try MeetingRepository(dbQueue: fixture.database.dbQueue).upsertSummary(SummaryContent(
                meetingId: fixture.first.id, title: original.title, document: original.databaseJSONString(), createdAt: .now
            ))
            var calls = 0
            let viewModel = CaptionViewModel(summaryGenerationRunner: { input in
                calls += 1
                let document = try SummaryService.generatedDocument(
                    from: #"{"title":"Weekly sync","sections":[{"heading":"Summary","blocks":[{"type":"paragraph","content":{"text":"_"}}]}],"action_items":[{"title":"Send notes"}]}"#,
                    context: .init(meetingId: input.promptContext.meetingId, createdAt: input.promptContext.recordedAt)
                )
                return .init(document: document, fileName: "summary.md", markdown: "Incomplete")
            })
            await fixture.select(fixture.first, in: viewModel, note: "")

            #expect(viewModel.triggerManualSummary(options: .init(exportOptions: .init(exportsToWorkspace: false))))
            let job = try #require(viewModel.summaryGenerationJobs.first)
            await job.task?.value

            #expect(job.isFinished && job.hasFailure)
            #expect(calls == 1)
            #expect(try fixture.summary(for: fixture.first.id)?.document == original.databaseJSONString())
        }
    }
#endif
