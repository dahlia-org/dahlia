import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct AgentChatInstructionsTests {
        @Test
        func instructionsPersistPerAccountAndCanBeCleared() throws {
            let suite = "AgentChatInstructionsTests.\(UUID.v7())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let accounts: [CodexRuntimeProvider] = [.local, .dahlia(connectionID: .v7()), .databricks(connectionID: .v7())]
            for account in accounts {
                #expect(AgentChatInstructions.load(for: account, defaults: defaults).isEmpty)
            }
            for (index, account) in accounts.enumerated() {
                defaults.set("Instructions \(index)\n日本語", forKey: AgentChatInstructions.defaultsKey(for: account))
            }
            let reloaded = try #require(UserDefaults(suiteName: suite))
            for (index, account) in accounts.enumerated() {
                #expect(AgentChatInstructions.load(for: account, defaults: reloaded) == "Instructions \(index)\n日本語")
            }
            defaults.set("", forKey: AgentChatInstructions.defaultsKey(for: .local))
            #expect(AgentChatInstructions.load(for: .local, defaults: defaults).isEmpty)
            #expect(!AgentChatInstructions.load(for: accounts[1], defaults: defaults).isEmpty)
        }
    }
#endif
