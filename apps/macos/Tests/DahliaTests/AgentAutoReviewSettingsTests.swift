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
    }
#endif
