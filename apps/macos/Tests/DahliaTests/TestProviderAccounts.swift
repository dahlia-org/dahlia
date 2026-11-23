#if canImport(Testing)
    @testable import Dahlia
    import Foundation
    import Testing

    /// Gives each test the Databricks connections it names, instead of the app database's.
    struct ProviderAccountsTrait: TestTrait, SuiteTrait, TestScoping {
        let connections: [ProviderAccountDirectory.Connection]

        var isRecursive: Bool { true }

        func provideScope(
            for _: Test, testCase _: Test.Case?, performing function: @Sendable () async throws -> Void
        ) async throws {
            try await ProviderAccountDirectory.$connections.withValue(connections) { try await function() }
        }
    }

    extension Trait where Self == ProviderAccountsTrait {
        static func providerAccounts(_ connections: [ProviderAccountDirectory.Connection]) -> Self {
            Self(connections: connections)
        }
    }
#endif

#if canImport(Testing)
    @testable import Dahlia
    import DahliaRuntimeSupport
    import Foundation

    /// The catalog tests read a gateway as a provider account under the ID every Databricks account used before; the
    /// ID itself does not change what the catalog builds.
    extension PiProviderConfiguration {
        static let databricksProviderIDs = [legacyDatabricksProviderID]

        static func databricksModels(workspaceURL: URL, services: [JSONValue]? = nil) throws -> [DatabricksModel] {
            try databricksModels(
                workspaceURL: workspaceURL, services: services, providerID: legacyDatabricksProviderID, isProviderAccount: true
            )
        }

        static func databricksProviders(_ models: [DatabricksModel], choices: [String: Bool], workspaceURL: URL) -> [String: JSONValue] {
            databricksProviders(models, choices: choices, workspaceURL: workspaceURL, providerID: legacyDatabricksProviderID)
        }
    }
#endif
