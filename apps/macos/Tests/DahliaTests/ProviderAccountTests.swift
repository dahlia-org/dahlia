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
            try database.dbQueue.write { db in
                try db.execute(sql: "UPDATE provider_accounts SET name = 'Work' WHERE id = ?", arguments: [connection.id])
            }

            var signedInAgain = connection
            signedInAgain.email = "me@example.com"
            try storage.saveConnections([signedInAgain])

            let record = try #require(try database.dbQueue.read { try DahliaAccountConnectionRecord.fetchOne($0, key: connection.id) })
            #expect(record.name == "Work" && record.email == "me@example.com")
        }

        @Test
        func eachRuntimeAccountMapsToTheProviderAccountsItsFeaturesUse() {
            let databricksID = UUID.v7()
            let dahliaID = UUID.v7()
            let databricks = CodexRuntimeProvider.databricks(connectionID: databricksID)
            let dahlia = CodexRuntimeProvider.dahlia(connectionID: dahliaID)

            #expect(CodexRuntimeProvider.local.providerAccounts.isEmpty)
            #expect(CodexRuntimeProvider.local.databricksConnectionID == nil)
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
        func bridgedPiProvidersComeFromTheProviderAccounts() {
            let databricks = CodexRuntimeProvider.databricks(connectionID: .v7())
            let dahlia = CodexRuntimeProvider.dahlia(connectionID: .v7())

            #expect(CodexRuntimeProvider.local.piBridgedProviderIDs.isEmpty)
            #expect(CodexRuntimeProvider.local.piProviderIDs == ["openai", "anthropic"])
            #expect(databricks.piProviderIDs == ["databricks"])
            #expect(databricks.piBridgedProviderIDs == ["databricks"])
            #expect(dahlia.piProviderIDs == ["dahlia"])
            #expect(databricks.providerAccount(piProviderID: "databricks") == databricks.providerAccounts.first)
            #expect(databricks.providerAccount(piProviderID: "dahlia") == nil)
            #expect(CodexRuntimeProvider.local.providerAccount(piProviderID: "openai") == nil)
        }
    }
#endif
