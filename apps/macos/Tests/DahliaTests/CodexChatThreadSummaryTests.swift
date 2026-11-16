#if canImport(Testing)
    import Foundation
    import Testing
    @testable import Dahlia

    struct CodexChatThreadSummaryTests {
        @Test(arguments: [
            ("databricks/system.ai.claude-opus-5-5", "Opus 5.5"),
            ("anthropic/claude-sonnet-5-5", "Sonnet 5.5"),
            ("openai/gpt-6-luna", "GPT 6 Luna"),
            ("custom/kimi-k3-1-pro", "Kimi K3.1 Pro"),
            ("claude-opus-5-5", "Opus 5.5"),
            ("custom/MyModel", "MyModel"),
        ])
        func compactModelName(_ model: String, _ expected: String) {
            let thread = CodexChatThreadSummary(id: "thread", title: "Title", updatedAt: .now, model: model)
            #expect(thread.modelDisplayName == expected)
            #expect(thread.model == model)
        }

        @Test(arguments: [nil, "", " "] as [String?])
        func missingModelHasNoDisplayName(_ model: String?) {
            let thread = CodexChatThreadSummary(id: "thread", title: "Title", updatedAt: .now, model: model)
            #expect(thread.modelDisplayName == nil)
        }
    }
#endif
