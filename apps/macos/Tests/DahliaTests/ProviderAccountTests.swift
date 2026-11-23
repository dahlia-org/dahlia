#if canImport(Testing)
    @testable import Dahlia
    import Foundation
    import GRDB
    import Testing

    struct ProviderAccountTests {
        @Test
        func signingInAgainKeepsTheNameTheUserGaveTheConnection() throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let storage = DatabricksOAuthStorage.local(database: { database.dbQueue })
            let connection = DatabricksConnection(id: .v7(), host: "https://dbc-1.cloud.databricks.com")
            try storage.saveConnections([connection])
            try storage.renameConnection(connection.id, "Work")
            #expect(try storage.loadConnections().first?.displayName == "Work")

            var signedInAgain = connection
            signedInAgain.email = "me@example.com"
            try storage.saveConnections([signedInAgain])

            let record = try #require(try database.dbQueue.read { try DahliaAccountConnectionRecord.fetchOne($0, key: connection.id) })
            #expect(record.name == "Work" && record.email == "me@example.com")

            // Clearing the name shows the workspace and email again.
            try storage.renameConnection(connection.id, nil)
            #expect(try storage.loadConnections().first?.displayName == "dbc-1 (me@example.com)")
        }

        @Test
        func eachRuntimeAccountMapsToTheProviderAccountsItsFeaturesUse() {
            let databricksID = UUID.v7()
            let dahliaID = UUID.v7()
            let databricks = CodexRuntimeProvider.databricks(connectionID: databricksID)
            let dahlia = CodexRuntimeProvider.dahlia(connectionID: dahliaID)

            #expect(ProviderAccountDirectory.$connections.withValue([]) { CodexRuntimeProvider.local.providerAccounts.isEmpty })
            #expect(databricks.providerAccounts == [.databricks(connectionID: databricksID)])
            #expect(dahlia.providerAccounts == [.dahlia(connectionID: dahliaID)])

            for capability in [ProviderCapability.model, .mcp, .calendar] {
                #expect(databricks.providerAccount(offering: capability) == .databricks(connectionID: databricksID))
            }
            #expect(dahlia.providerAccount(offering: .model) == .dahlia(connectionID: dahliaID))
            #expect(dahlia.providerAccount(offering: .calendar) == nil)
            #expect(databricks.databricksConnectionID == databricksID)
            #expect(dahlia.databricksConnectionID == nil)
            // Storage and database are defined for later; nothing offers them yet.
            for capability in [ProviderCapability.storage, .database] {
                #expect(databricks.providerAccount(offering: capability) == nil)
                #expect(dahlia.providerAccount(offering: capability) == nil)
            }
        }

        @Test
        func eachConnectionIsAProviderNamedByItsHostAndTheAccountUsesThemAll() {
            let first = ProviderAccountDirectory.Connection(id: .v7(), workspaceURL: URL(string: "https://dbc-1.cloud.databricks.com")!)
            let second = ProviderAccountDirectory.Connection(id: .v7(), workspaceURL: URL(string: "https://dbc-2.cloud.databricks.com:8443")!)
            ProviderAccountDirectory.$connections.withValue([first, second]) {
                let local = CodexRuntimeProvider.local
                #expect(local.providerAccounts == [.databricks(connectionID: first.id), .databricks(connectionID: second.id)])
                #expect(local.piBridgedProviderIDs == ["dbc-1.cloud.databricks.com", "dbc-2.cloud.databricks.com:8443"])
                #expect(local.piProviderIDs == ["openai", "anthropic", "dbc-1.cloud.databricks.com", "dbc-2.cloud.databricks.com:8443"])
                #expect(local.providerAccount(piProviderID: "dbc-2.cloud.databricks.com:8443") == .databricks(connectionID: second.id))
                #expect(local.providerAccount(piProviderID: "openai") == nil)
                #expect(PiProviderConfiguration.isOwnProvider("dbc-1.cloud.databricks.com"))
                #expect(!PiProviderConfiguration.isOwnProvider("other.cloud.databricks.com"))
                #expect(AgentMCPProvider(workspaceURL: first.workspaceURL).isAccount)
            }
            ProviderAccountDirectory.$connections.withValue([]) {
                #expect(CodexRuntimeProvider.local.piBridgedProviderIDs.isEmpty)
                #expect(CodexRuntimeProvider.local.piProviderIDs == ["openai", "anthropic"])
                #expect(CodexRuntimeProvider.dahlia(connectionID: .v7()).piProviderIDs == ["dahlia"])
            }
        }
    }
#endif
