#if canImport(Testing)
    import Foundation
    import GRDB
    import Testing
    @testable import Dahlia

    @MainActor
    struct WorkspaceGenerationSettingsTests {
        @Test
        func remoteProcessingDefaultsToDirectAudioSummary() {
            #expect(WorkspaceGenerationSettings().processing.remote.workflow == .combined)
        }

        @Test
        func remoteProcessingDecodesWithoutSeparateTranscriptSummarySettings() throws {
            let settings = try JSONDecoder().decode(
                WorkspaceGenerationSettings.self,
                from: Data(#"{"processing":{"location":"remote","remote":{"workflow":"combined","summaryModel":"audio","reasoningEffort":"medium"}}}"#
                    .utf8)
            )

            #expect(settings.processing.remote.summaryModel == "audio")
            #expect(settings.processing.remote.transcriptSummaryModel == nil)
            #expect(settings.processing.remote.transcriptSummaryReasoningEffort == nil)
        }

        @Test
        func currentTranscriptSummaryChoicesSupersedeLegacyLocalFallbacks() {
            var settings = WorkspaceGenerationSettings()
            settings.processing.remote.summaryModel = "legacy-model"
            settings.processing.remote.reasoningEffort = "high"

            settings.setTranscriptSummaryModel("current-model")
            settings.setTranscriptSummaryReasoningEffort(nil)

            #expect(settings.processing.remote.transcriptSummaryModel == "current-model")
            #expect(settings.processing.remote.transcriptSummaryReasoningEffort == nil)
            #expect(settings.processing.remote.summaryModel == nil)
            #expect(settings.processing.remote.reasoningEffort == nil)
        }

        @Test
        func legacyTranscriptionSettingsRestoreTheSharedLiveDraftOnly() throws {
            let settings = try JSONDecoder().decode(
                WorkspaceGenerationSettings.self,
                from: Data("""
                {"transcription":{"localeIdentifier":"fr_FR","automaticLanguageDetection":true,"languageScope":"selected","languageIdentifiers":["en","fr"],"liveTranscriptDraft":true}}
                """.utf8)
            )

            #expect(settings.legacyTranscription?.localeIdentifier == "fr_FR")
            #expect(settings.legacyTranscription?.automaticLanguageDetection == true)
            #expect(settings.legacyTranscription?.languageIdentifiers == ["en", "fr"])
            #expect(settings.liveTranscriptDraft)
            let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
            #expect(encoded["transcription"] == nil)
            #expect(encoded["liveTranscriptDraft"] as? Bool == true)
        }

        @Test
        func disabledLiveDraftIsOmittedForOlderServers() throws {
            let encoded = try #require(JSONSerialization.jsonObject(
                with: JSONEncoder().encode(WorkspaceGenerationSettings())
            ) as? [String: Any])

            #expect(encoded["liveTranscriptDraft"] == nil)
        }

    }
#endif
