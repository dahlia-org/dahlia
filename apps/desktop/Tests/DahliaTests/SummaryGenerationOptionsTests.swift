@testable import Dahlia

#if canImport(Testing)
    import Foundation
    import Testing

    @MainActor
    struct SummaryGenerationOptionsTests {
        @Test
        func oneOffOverridesKeepSharedDefaultsUnchanged() {
            let shared = WorkspaceGenerationSettings()
            let options = SummaryGenerationOptions(
                exportOptions: .manual,
                detailLevel: .concise,
                overrides: .init(outputLanguage: .fr, model: "chosen", reasoningEffort: "low")
            )
            let effective = options.applying(to: shared, usesServer: true)
            #expect(effective.outputLanguage == .fr)
            #expect(effective.summary.style == .concise)
            #expect(effective.processing.location == .local)
            #expect(effective.processing.remote.summaryModel == "chosen")
            #expect(effective.processing.remote.reasoningEffort == "low")
            #expect(shared == WorkspaceGenerationSettings())
        }

        @Test(arguments: [false, true])
        func changingModelResetsEffortBeforeGenerating(usesServer: Bool) throws {
            var shared = WorkspaceGenerationSettings()
            shared.local.reasoningEffort = "high"
            shared.processing.remote.reasoningEffort = "high"
            var overrides = SummaryGenerationOptions.Overrides()
            overrides.selectModel("first", defaultReasoningEffort: "high")
            overrides.reasoningEffort = "high"
            overrides.selectModel("first", defaultReasoningEffort: "low")
            #expect(overrides.reasoningEffort == "high")
            // The Server resolves its default; the local catalog supplies a supported effort.
            overrides.selectModel("second", defaultReasoningEffort: usesServer ? "" : "low")
            let options = SummaryGenerationOptions(exportOptions: .manual, overrides: overrides)
            let request = try JSONDecoder().decode(SummaryGenerationOptions.self, from: JSONEncoder().encode(options))
            let effective = request.applying(to: shared, usesServer: usesServer)
            if usesServer {
                #expect(effective.processing.remote.summaryModel == "second")
                #expect(effective.processing.remote.reasoningEffort == nil)
            } else {
                #expect(effective.local.model == "second")
                #expect(effective.local.reasoningEffort == "low")
            }
            #expect(shared.local.reasoningEffort == "high")
            #expect(shared.processing.remote.reasoningEffort == "high")
            overrides.selectModel(nil, defaultReasoningEffort: "low")
            #expect(overrides.model == nil && overrides.reasoningEffort == nil)
        }

        @Test
        func sourceChangesRejectUnavailableModelsIncludingWorkspaceDefaults() {
            var overrides = SummaryGenerationOptions.Overrides()
            overrides.selectModel("transcript-only", defaultReasoningEffort: "")
            #expect(overrides.isModelAvailable(defaultModel: "transcript-only", modelIDs: ["transcript-only", "audio"], allowsAutomatic: true))
            #expect(!overrides.isModelAvailable(defaultModel: "transcript-only", modelIDs: ["audio"], allowsAutomatic: true))
            overrides.selectModel(nil, defaultReasoningEffort: nil)
            #expect(!overrides.isModelAvailable(defaultModel: "transcript-only", modelIDs: ["audio"], allowsAutomatic: true))
            overrides.selectModel("audio", defaultReasoningEffort: "")
            #expect(overrides.isModelAvailable(defaultModel: "transcript-only", modelIDs: ["audio"], allowsAutomatic: true))
            overrides.selectModel("", defaultReasoningEffort: "")
            #expect(overrides.isModelAvailable(defaultModel: "transcript-only", modelIDs: ["audio"], allowsAutomatic: true))
            #expect(!overrides.isModelAvailable(defaultModel: "transcript-only", modelIDs: ["audio"], allowsAutomatic: false))
        }

        @Test
        func mergingCombinesExports() {
            let merged = SummaryGenerationOptions.merging([
                SummaryGenerationOptions(
                    exportOptions: SummaryExportOptions(exportsToWorkspace: true, exportsToGoogleDocs: false),
                    detailLevel: .standard
                ),
                SummaryGenerationOptions(
                    exportOptions: SummaryExportOptions(exportsToWorkspace: false, exportsToGoogleDocs: true),
                    detailLevel: .eventSession
                ),
                SummaryGenerationOptions(
                    exportOptions: SummaryExportOptions(exportsToWorkspace: false, exportsToGoogleDocs: false),
                    detailLevel: .detailed
                ),
            ])

            #expect(merged.exportOptions == SummaryExportOptions(
                exportsToWorkspace: true,
                exportsToGoogleDocs: true
            ))
            #expect(merged.detailLevel == .eventSession)
        }

        @Test
        func sourceIsBackwardCompatibleAndMergedWithManualOptions() throws {
            let legacy = try JSONDecoder().decode(
                SummaryGenerationOptions.self,
                from: Data(#"{"exportOptions":{"exportsToWorkspace":true,"exportsToGoogleDocs":false},"detailLevel":"high"}"#.utf8)
            )
            #expect(legacy.source == nil)
            #expect(legacy.useSavedTranscript == nil)
            let offline = SummaryGenerationOptions(exportOptions: .manual, useSavedTranscript: true)
            #expect(try JSONDecoder().decode(SummaryGenerationOptions.self, from: JSONEncoder().encode(offline)).useSavedTranscript == true)
            #expect(SummaryGenerationOptions.merging([offline, legacy]).useSavedTranscript != true)
            #expect(SummaryGenerationOptions.merging([offline, offline]).useSavedTranscript == true)
            #expect(SummaryGenerationOptions.merging([]).useSavedTranscript != true)

            let merged = SummaryGenerationOptions.merging([
                legacy,
                SummaryGenerationOptions(exportOptions: .manual, source: .audio),
            ])
            #expect(merged.source == SummaryGenerationSource.audio)
        }
    }
#endif
