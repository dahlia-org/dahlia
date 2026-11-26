#if canImport(Testing)
    import Foundation
    import Testing
    @testable import Dahlia

    struct AgentConnectionBindingTests {
        private func settings() throws -> AgentMCPSettings {
            let gateway = try AgentMCPProvider(workspaceURL: #require(URL(string: "https://original.example.com")))
            return AgentMCPSettings(providers: [gateway], servers: [
                AgentMCPServer(id: .v7(), name: "gmail", providerID: gateway.id, service: "system.ai.gmail"),
            ])
        }

        /// A Worker's process keeps the connection IDs it started with; a server registered again under the same name is
        /// another connection, so a queued Worker started with the old one does not run on it.
        @Test(arguments: ["registration", "endpoint"])
        func aReusedAliasIsAnotherConnection(change: String) throws {
            let original = try settings()
            let id = try #require(original.connectionID(for: "gmail"))
            var replacement = original
            let gateway = try AgentMCPProvider(workspaceURL: #require(URL(string: "https://replacement.example.com")))
            replacement.providers = [gateway]
            replacement.servers = [AgentMCPServer(
                id: change == "registration" ? .v7() : original.servers[0].id,
                name: "gmail", providerID: gateway.id, service: "system.ai.gmail"
            )]
            #expect(replacement.connectionID(for: "gmail") != id)
            #expect(replacement.serverName(for: id) == nil)
        }
    }
#endif
