#if canImport(Testing)
    import Foundation
    import Testing
    @testable import Dahlia

    struct DatabricksCatalogSchemaTests {
        @Test
        func commonProviderSettingPreservesAccountIsolation() async throws {
            let first = UUID.v7()
            let second = UUID.v7()
            let repository = try await providerSettingsRepository(accounts: [.databricks(connectionID: first), .databricks(connectionID: second)])
            let updated = try #require(DatabricksCatalogSchema("main.shared"))
            try await DatabricksCatalogSchema.save(updated, connectionID: first, repository: repository)
            #expect(try await DatabricksCatalogSchema.load(connectionID: first, repository: repository) == updated)
            #expect(try await DatabricksCatalogSchema.load(connectionID: second, repository: repository) == nil)
            try await DatabricksCatalogSchema.save(nil, connectionID: first, repository: repository)
            #expect(try await DatabricksCatalogSchema.load(connectionID: first, repository: repository) == nil)
        }
    }
#endif
