import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct GenerationModelFallbackSettingsTests {
        @Test
        func olderSettingsStartWithoutFallback() throws {
            let settings = try JSONDecoder().decode(
                WorkspaceGenerationSettings.self,
                from: Data(#"{"local":{"model":"primary","reasoningEffort":"high"},"imageAnalysis":{"enabled":true,"model":"vision"}}"#.utf8)
            )
            #expect(settings.local.fallbackModel == nil)
            #expect(settings.imageAnalysis.fallbackModel == nil)
        }

        @Test(arguments: ["local", "server", "databricks"])
        func fallbackPreferencesAreAccountLocalCapturedByJobsAndCanBeCleared(kind: String) throws {
            let suite = "FallbackSettings-\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let connectionID: UUID? = kind == "server" ? .v7() : nil
            let databricksID: UUID? = kind == "databricks" ? .v7() : nil
            let workspace = WorkspaceRecord(
                id: .v7(), path: nil, name: "Workspace", createdAt: .now, lastOpenedAt: .now,
                accountConnectionId: connectionID, databricksConnectionId: databricksID
            )
            var account = AccountInferenceSettings(workspace: workspace, defaults: defaults)
            account.local.fallbackModel = "summary-fallback"
            account.imageAnalysis.fallbackModel = "vision-fallback"
            account.save(connectionID: connectionID, databricksConnectionID: databricksID, defaults: defaults)
            let restored = AccountInferenceSettings(workspace: workspace, defaults: defaults)
            #expect(restored.local.fallbackModel == "summary-fallback")
            #expect(restored.imageAnalysis.fallbackModel == "vision-fallback")

            let job = SummaryGenerationSettings.current(
                workspaceAISettings: WorkspaceAISettingsModel(setupDefaults: defaults), workspace: workspace, defaults: defaults
            )
            let decoded = try JSONDecoder().decode(SummaryGenerationSettings.self, from: JSONEncoder().encode(job))
            #expect(decoded.workspacePreferences?.local.fallbackModel == "summary-fallback")
            #expect(decoded.applying(detailLevel: .concise).workspacePreferences?.imageAnalysis.fallbackModel == "vision-fallback")
            #expect(decoded.applying(options: .manual).workspacePreferences?.local.fallbackModel == "summary-fallback")

            account.local.fallbackModel = nil
            account.imageAnalysis.fallbackModel = nil
            account.save(connectionID: connectionID, databricksConnectionID: databricksID, defaults: defaults)
            let cleared = AccountInferenceSettings(workspace: workspace, defaults: defaults)
            #expect(cleared.local.fallbackModel == nil && cleared.imageAnalysis.fallbackModel == nil)
            #expect(job.workspacePreferences?.local.fallbackModel == "summary-fallback")
            #expect(workspace.generationSettings.local.fallbackModel == nil)
        }
    }
#endif
