#if canImport(Testing)
    import Foundation
    import GRDB
    import Synchronization
    import Testing
    @testable import Dahlia

    private actor TestUnityCatalog: DatabricksUnityCatalogProviding {
        nonisolated let valid = Mutex(true)
        var schemaError: (any Error)?
        var created: [(String, String)] = []
        private var held: CheckedContinuation<[String], Never>?
        var isWaiting: Bool { held != nil }

        nonisolated func validate() throws {
            guard valid.withLock({ $0 }) else { throw CancellationError() }
        }

        func catalogs() async throws -> [String] { ["main", "slow"] }

        func schemas(in catalog: String) async throws -> [String] {
            if let schemaError { throw schemaError }
            if catalog == "slow" { return await withCheckedContinuation { held = $0 } }
            return ["existing"]
        }

        func createSchema(named name: String, in catalog: String) async throws -> String {
            try validate()
            if let schemaError { throw schemaError }
            created.append((name, catalog))
            return name
        }

        func release() { held?.resume(returning: ["stale"])
            held = nil
        }

        func fail(_ error: (any Error)?) { schemaError = error }
    }

    @MainActor
    struct DatabricksCatalogSchemaSettingsModelTests {
        private let connection = DatabricksConnection(id: .v7(), host: "https://workspace.example")

        private func model(_ client: TestUnityCatalog) async throws -> (DatabricksCatalogSchemaSettingsModel, MeetingRepository) {
            let repository = try await providerSettingsRepository(accounts: [.databricks(connectionID: connection.id)])
            return (DatabricksCatalogSchemaSettingsModel(connection: connection, repository: repository, makeClient: { client }), repository)
        }

        @Test
        func existingSelectionsAreRestoredAndOnlyExplicitSaveChangesTheAccount() async throws {
            let (model, repository) = try await model(TestUnityCatalog())
            let initial = try #require(DatabricksCatalogSchema("main.existing"))
            try await DatabricksCatalogSchema.save(initial, connectionID: connection.id, repository: repository)
            await model.loadCatalogs()
            #expect(model.catalog == "main")
            #expect(!model.canSave)
            await model.loadSchemas()
            #expect(model.schema == "existing" && model.canSave)
            model.schema = "not-listed"
            #expect(!model.canSave)
            #expect(await !model.save())
            #expect(try await DatabricksCatalogSchema.load(connectionID: connection.id, repository: repository) == initial)
            model.schema = "existing"
            #expect(await model.save())
            #expect(await model.clear())
            #expect(!model.canClear)
            #expect(try await DatabricksCatalogSchema.load(connectionID: connection.id, repository: repository) == nil)
        }

        @Test
        func switchingCatalogsDiscardsLateSchemaResults() async throws {
            let client = TestUnityCatalog()
            let (model, _) = try await model(client)
            await model.loadCatalogs()
            model.selectCatalog("slow")
            let slow = Task { await model.loadSchemas() }
            #expect(await pollUntil { await client.isWaiting })
            model.selectCatalog("main")
            #expect(model.schema.isEmpty && model.schemas.isEmpty)
            await model.loadSchemas()
            await client.release()
            await slow.value
            #expect(model.schemas == ["existing"])
            #expect(model.catalog == "main" && !model.isLoadingSchemas)
        }

        @Test
        func schemaCreationSelectsTheResultButDoesNotSaveTheDefault() async throws {
            let client = TestUnityCatalog()
            let (model, repository) = try await model(client)
            await model.loadCatalogs()
            model.selectCatalog("main")
            await model.loadSchemas()
            model.newSchemaName = " New_Schema "
            #expect(model.canCreate)
            await model.createSchema()
            #expect(model.schema == "new_schema")
            #expect(model.createdSchema == "main.new_schema")
            #expect(await client.created.count == 1)
            #expect(await client.created.first?.1 == "main")
            #expect(try await DatabricksCatalogSchema.load(connectionID: connection.id, repository: repository) == nil)
            #expect(await model.save())
            #expect(try await DatabricksCatalogSchema.load(connectionID: connection.id, repository: repository)?.description == "main.new_schema")
        }

        @Test
        func permissionFailureRetainsTheSelectionAndAllowsRetry() async throws {
            let client = TestUnityCatalog()
            let (model, _) = try await model(client)
            await model.loadCatalogs()
            model.selectCatalog("main")
            await model.loadSchemas()
            model.schema = "existing"
            model.newSchemaName = "new_schema"
            let error = ProviderStorageError.requestFailed(statusCode: 403, message: "CREATE SCHEMA required")
            await client.fail(error)
            await model.createSchema()
            #expect(model.schema == "existing")
            #expect(model.errorMessage == error.localizedDescription)
            #expect(model.canCreate && !model.isCreating)
            await client.fail(nil)
            await model.createSchema()
            #expect(model.schema == "new_schema" && model.errorMessage == nil)
        }

        @Test(arguments: ["", "two words", "a.b", "a/b", "a\u{0000}b", "existing", String(repeating: "x", count: 256)])
        func invalidOrExistingNamesNeverCreateASchema(_ name: String) async throws {
            let client = TestUnityCatalog()
            let (model, _) = try await model(client)
            await model.loadCatalogs()
            model.selectCatalog("main")
            await model.loadSchemas()
            model.newSchemaName = name
            #expect(!model.canCreate)
            await model.createSchema()
            #expect(await client.created.isEmpty)
        }

        @Test
        func listingFailureKeepsTheSavedDefaultAndCanBeRetried() async throws {
            let client = TestUnityCatalog()
            let (model, repository) = try await model(client)
            let initial = try #require(DatabricksCatalogSchema("main.existing"))
            try await DatabricksCatalogSchema.save(initial, connectionID: connection.id, repository: repository)
            await model.loadCatalogs()
            let error = URLError(.timedOut)
            await client.fail(error)
            await model.loadSchemas()
            #expect(model.errorMessage == error.localizedDescription)
            #expect(!model.isLoadingSchemas && !model.canSave)
            #expect(try await DatabricksCatalogSchema.load(connectionID: connection.id, repository: repository) == initial)
            await client.fail(nil)
            await model.loadCatalogs()
            await model.loadSchemas()
            #expect(model.errorMessage == nil && model.canSave)
            #expect(model.schema == "existing")
        }

        @Test
        func databaseWriteFailureKeepsTheSavedNamespaceAndAllowsRetry() async throws {
            let (model, repository) = try await model(TestUnityCatalog())
            await model.loadCatalogs()
            model.selectCatalog("main")
            await model.loadSchemas()
            model.schema = "existing"
            try await repository.dbQueue.write { db in
                try db
                    .execute(
                        sql: "CREATE TRIGGER reject_settings BEFORE UPDATE OF settingsJSON ON provider_accounts BEGIN SELECT RAISE(ABORT, 'test failure'); END"
                    )
            }
            #expect(await !model.save())
            #expect(model.errorMessage != nil && !model.isSaving && model.canSave)
            #expect(try await DatabricksCatalogSchema.load(connectionID: connection.id, repository: repository) == nil)
            try await repository.dbQueue.write { try $0.execute(sql: "DROP TRIGGER reject_settings") }
            #expect(await model.save())
            #expect(try await DatabricksCatalogSchema.load(connectionID: connection.id, repository: repository)?.description == "main.existing")
        }

        @Test
        func changedSignInCannotSaveAnEarlierSelection() async throws {
            let client = TestUnityCatalog()
            let (model, repository) = try await model(client)
            await model.loadCatalogs()
            model.selectCatalog("main")
            await model.loadSchemas()
            model.schema = "existing"
            client.valid.withLock { $0 = false }
            #expect(await !model.save())
            #expect(model.errorMessage == L10n.databricksCatalogAccountChanged)
            #expect(try await DatabricksCatalogSchema.load(connectionID: connection.id, repository: repository) == nil)
        }
    }
#endif
