import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct AgentAutoReviewSettingsTests {
        @Test
        func reviewerSelectionIsAccountScopedAndCanReturnToChatModel() throws {
            let suite = "AgentAutoReviewSettingsTests.\(UUID.v7())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let server = CodexRuntimeProvider.dahlia(connectionID: .v7())
            #expect(AgentAutoReviewSettings.model(for: .local, defaults: defaults).isEmpty)
            #expect(AgentAutoReviewSettings.model(for: server, defaults: defaults).isEmpty)
            defaults.set("reviewer/fast", forKey: AgentAutoReviewSettings.defaultsKey(for: .local))
            #expect(AgentAutoReviewSettings.model(for: .local, defaults: defaults) == "reviewer/fast")
            #expect(AgentAutoReviewSettings.model(for: server, defaults: defaults).isEmpty)
            defaults.set("", forKey: AgentAutoReviewSettings.defaultsKey(for: .local))
            #expect(AgentAutoReviewSettings.model(for: .local, defaults: defaults).isEmpty)
        }

        @Test
        func triageIsOptInAndAccountScoped() throws {
            let suite = "AgentAutoReviewSettingsTests.\(UUID.v7())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let server = CodexRuntimeProvider.dahlia(connectionID: .v7())
            #expect(!AgentAutoReviewSettings.triageEnabled(for: .local, defaults: defaults))
            defaults.set(true, forKey: AgentAutoReviewSettings.triageDefaultsKey(for: .local))
            #expect(AgentAutoReviewSettings.triageEnabled(for: .local, defaults: defaults))
            #expect(!AgentAutoReviewSettings.triageEnabled(for: server, defaults: defaults))
            defaults.set(false, forKey: AgentAutoReviewSettings.triageDefaultsKey(for: .local))
            #expect(!AgentAutoReviewSettings.triageEnabled(for: .local, defaults: defaults))
        }

        @Test
        func triageRequiresOpenJevWithTheClassifierAPI() throws {
            let gateway = try AgentMCPProvider(workspaceURL: #require(URL(string: "https://example.cloud.databricks.com")))
            func service(_ name: String, api: String) -> JSONValue {
                .object(["name": .string("model-services/\(name)"), "supported_api_types": .array([.string(api)])])
            }
            #expect(AgentAutoReviewSettings.triageConfiguration(services: [], gateway: gateway) == nil)
            #expect(AgentAutoReviewSettings.triageConfiguration(services: [
                service("system.ai.typesafeai-jev", api: "typesafe/v1/systemone"),
                service(AgentAutoReviewSettings.triageModelID, api: "mlflow/v1/responses"),
            ], gateway: gateway) == nil)
            let configuration = try #require(AgentAutoReviewSettings.triageConfiguration(services: [
                service(AgentAutoReviewSettings.triageModelID, api: "typesafe/v1/systemone"),
            ], gateway: gateway)?.objectValue)
            #expect(configuration["model"] == .string(AgentAutoReviewSettings.triageModelID))
            #expect(configuration["provider"] == .string(gateway.id))
            #expect(configuration["endpoint"] == .string("https://example.cloud.databricks.com/ai-gateway/typesafe/v1/systemone"))
            #expect(configuration["apiKey"] == nil)
        }
    }
#endif
