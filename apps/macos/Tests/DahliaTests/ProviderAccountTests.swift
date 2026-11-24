#if canImport(Testing)
    import Foundation
    import GRDB
    import Testing
    @testable import Dahlia

    struct ProviderAccountTests {
        @Test
        func removingPromotedProviderRetiresRegistrationDespiteStaleSaves() throws {
            let suite = "RemovedProvider.\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            let root = FileManager.default.temporaryDirectory.appending(path: suite)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer {
                defaults.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: root)
            }
            let removed = try AgentMCPProvider(workspaceURL: #require(URL(string: "https://removed.example.com")))
            let kept = try AgentMCPProvider(workspaceURL: #require(URL(string: "https://kept.example.com")))
            let stale = AgentMCPSettings(
                providers: [removed, kept],
                servers: [removed, kept].map { .init(id: .v7(), name: $0.id, providerID: $0.id, service: "system.ai.github") },
                listedServices: [removed.id: ["system.ai.github"]]
            )
            stale.save(defaults: defaults)
            try PiProviderConfiguration.write([removed.id: .object([:]), kept.id: .object([:])], agentURL: root)
            try PiProviderConfiguration.writeMCPServers(stale.piServers, agentURL: root)
            let auth = Data(#"{"removed.example.com":{"type":"oauth","refresh":"synthetic"}}"#.utf8)
            try auth.write(to: root.appending(path: "auth.json"))

            try AgentMCPSettings.removeProviderAccount(removed.id, agentURL: root, defaults: defaults)
            // An old window or service listing cannot restore the retired host on its next save.
            stale.save(defaults: defaults)
            let saved = AgentMCPSettings.load(defaults: defaults)
            #expect(saved.providers == [kept])
            #expect(saved.servers.map(\.providerID) == [kept.id])
            #expect(saved.listedServices?[removed.id] == nil)
            let models = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: root.appending(path: "models.json")))
            #expect(models.objectValue?["providers"]?.objectValue?.keys.sorted() == [kept.id])
            #expect(try Data(contentsOf: root.appending(path: "auth.json")) == auth)
            let mcp = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: root.appending(path: "mcp.json")))
            #expect(mcp.objectValue?["mcpServers"]?.objectValue?.keys.sorted() == [kept.id])

            AgentMCPSettings.allowProviderAccount(removed.id, defaults: defaults)
            stale.save(defaults: defaults)
            #expect(AgentMCPSettings.load(defaults: defaults).providers == [removed, kept])
        }

        @Test
        func calendarChoiceCanUseAnyDatabricksConnection() throws {
            let suite = "CalendarProviderChoice.\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let first = try ProviderAccountDirectory.Connection(id: .v7(), workspaceURL: #require(URL(string: "https://first.example.com")))
            let second = try ProviderAccountDirectory.Connection(id: .v7(), workspaceURL: #require(URL(string: "https://second.example.com")))
            ProviderAccountDirectory.$connections.withValue([first, second]) {
                defaults.set(second.id.uuidString, forKey: GoogleCalendarProvider.userDefaultsKey)
                #expect(GoogleCalendarProvider.current(defaults: defaults) == .databricks(connectionID: second.id))
                defaults.set("google", forKey: GoogleCalendarProvider.userDefaultsKey)
                #expect(GoogleCalendarProvider.current(defaults: defaults) == .unassigned)
            }
        }

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
        func theAppsAccountMapsToTheProviderAccountsItsFeaturesUse() throws {
            let databricksID = UUID.v7()
            let dahliaID = UUID.v7()
            let connection = try ProviderAccountDirectory.Connection(
                id: databricksID,
                workspaceURL: #require(URL(string: "https://dbc.cloud.databricks.com"))
            )

            #expect(ProviderAccountDirectory.$connections.withValue([]) { ProviderAccountDirectory.accounts.isEmpty })
            ProviderAccountDirectory.$connections.withValue([connection]) {
                #expect(ProviderAccountDirectory.accounts == [.databricks(connectionID: databricksID)])
                for capability in [ProviderCapability.model, .mcp, .calendar] {
                    #expect(ProviderAccountDirectory.account(offering: capability) == .databricks(connectionID: databricksID))
                }
                #expect(ProviderAccountDirectory.databricksConnectionID == databricksID)
                // Storage and database are defined for later; nothing offers them yet.
                for capability in [ProviderCapability.storage, .database] {
                    #expect(ProviderAccountDirectory.account(offering: capability) == nil)
                }
            }
            // The signed-in Dahlia account's Gateway is a provider account of the app's account, after Databricks.
            ProviderAccountDirectory.$connections.withValue([connection]) {
                ProviderAccountDirectory.$dahliaConnections.withValue([dahliaID, .v7()]) {
                    #expect(ProviderAccountDirectory.accounts == [.databricks(connectionID: databricksID), .dahlia(connectionID: dahliaID)])
                    #expect(ProviderAccountDirectory.account(piProviderID: "dahlia") == .dahlia(connectionID: dahliaID))
                    #expect(PiProviderConfiguration.bridgedProviderIDs.contains("dahlia"))
                }
            }
            // Without Databricks, the Gateway serves models and nothing else.
            ProviderAccountDirectory.$connections.withValue([]) {
                ProviderAccountDirectory.$dahliaConnections.withValue([dahliaID]) {
                    #expect(ProviderAccountDirectory.account(offering: .model) == .dahlia(connectionID: dahliaID))
                    #expect(ProviderAccountDirectory.account(offering: .calendar) == nil)
                    #expect(ProviderAccountDirectory.databricksConnectionID == nil)
                }
            }
        }

        @Test
        func eachConnectionIsAProviderNamedByItsHostAndTheAccountUsesThemAll() throws {
            let first = try ProviderAccountDirectory.Connection(id: .v7(), workspaceURL: #require(URL(string: "https://dbc-1.cloud.databricks.com")))
            let second = try ProviderAccountDirectory.Connection(
                id: .v7(),
                workspaceURL: #require(URL(string: "https://dbc-2.cloud.databricks.com:8443"))
            )
            ProviderAccountDirectory.$connections.withValue([first, second]) {
                #expect(ProviderAccountDirectory.accounts == [.databricks(connectionID: first.id), .databricks(connectionID: second.id)])
                #expect(PiProviderConfiguration.bridgedProviderIDs == ["dbc-1.cloud.databricks.com", "dbc-2.cloud.databricks.com:8443"])
                #expect(PiProviderConfiguration.providerIDs == [
                    "openai",
                    "anthropic",
                    "dbc-1.cloud.databricks.com",
                    "dbc-2.cloud.databricks.com:8443",
                ])
                #expect(ProviderAccountDirectory.account(piProviderID: "dbc-2.cloud.databricks.com:8443") == .databricks(connectionID: second.id))
                #expect(ProviderAccountDirectory.account(piProviderID: "openai") == nil)
                #expect(PiProviderConfiguration.isOwnProvider("dbc-1.cloud.databricks.com"))
                #expect(!PiProviderConfiguration.isOwnProvider("other.cloud.databricks.com"))
                #expect(AgentMCPProvider(workspaceURL: first.workspaceURL).isAccount)
            }
            ProviderAccountDirectory.$connections.withValue([]) {
                #expect(PiProviderConfiguration.bridgedProviderIDs.isEmpty)
                #expect(PiProviderConfiguration.providerIDs == ["openai", "anthropic"])
            }
        }
    }
#endif
