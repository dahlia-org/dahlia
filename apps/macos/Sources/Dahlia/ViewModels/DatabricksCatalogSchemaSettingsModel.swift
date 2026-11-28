import Foundation
import Observation

@Observable
@MainActor
final class DatabricksCatalogSchemaSettingsModel {
    private(set) var catalogs: [String] = []
    private(set) var schemas: [String] = []
    private(set) var catalog = ""
    var schema = ""
    var newSchemaName = ""
    private(set) var isLoadingCatalogs = false
    private(set) var isLoadingSchemas = false
    private(set) var isCreating = false
    private(set) var errorMessage: String?
    private(set) var createdSchema: String?
    private let connectionID: UUID
    private let repository: MeetingRepository?
    private(set) var savedLocation: DatabricksCatalogSchema?
    private(set) var isSaving = false
    private let makeClient: @Sendable () async throws -> any DatabricksUnityCatalogProviding
    private var client: (any DatabricksUnityCatalogProviding)?
    private var revision = 0

    init(
        connection: DatabricksConnection,
        repository: MeetingRepository? = nil,
        makeClient: (@Sendable () async throws -> any DatabricksUnityCatalogProviding)? = nil
    ) {
        connectionID = connection.id
        self.repository = repository
        self.makeClient = makeClient ?? {
            let oauth = DatabricksOAuthService.shared
            let authorization = try await oauth.storageAuthorization(connectionID: connection.id)
            return try DatabricksUnityCatalogClient(host: oauth.normalizedWorkspaceURL(connection.host), authorization: authorization)
        }
    }

    var canSave: Bool {
        !isLoadingCatalogs && !isLoadingSchemas && !isCreating && !isSaving && catalogs.contains(catalog) && schemas.contains(schema)
    }

    var canClear: Bool { savedLocation != nil && !isSaving }

    var canCreate: Bool {
        !isLoadingCatalogs && !isLoadingSchemas && !isCreating && !isSaving && catalogs.contains(catalog)
            && DatabricksCatalogSchema("\(catalog).\(normalizedNewSchemaName)") != nil
            && !schemas.contains(normalizedNewSchemaName)
    }

    private var normalizedNewSchemaName: String { newSchemaName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    func loadCatalogs() async {
        guard !isLoadingCatalogs, !isCreating, !isSaving else { return }
        isLoadingCatalogs = true
        errorMessage = nil
        selectCatalog("")
        catalogs = []
        client = nil
        defer { isLoadingCatalogs = false }
        do {
            savedLocation = try await DatabricksCatalogSchema.load(connectionID: connectionID, repository: repository)
            let client = try await makeClient()
            let catalogs = try await client.catalogs()
            try Task.checkCancellation()
            self.client = client
            self.catalogs = catalogs
            if let saved = savedLocation, catalogs.contains(saved.catalog) {
                selectCatalog(saved.catalog)
            }
        } catch { show(error) }
    }

    func selectCatalog(_ value: String) {
        guard !isCreating else { return }
        revision += 1
        catalog = value
        schema = ""
        schemas = []
        isLoadingSchemas = false
        errorMessage = nil
    }

    func loadSchemas() async {
        guard !catalog.isEmpty, let client else { return }
        let catalog = catalog
        let revision = revision
        isLoadingSchemas = true
        defer { if self.revision == revision { isLoadingSchemas = false } }
        do {
            let schemas = try await client.schemas(in: catalog)
            try Task.checkCancellation()
            guard self.revision == revision else { return }
            self.schemas = schemas
            if let saved = savedLocation,
               saved.catalog == catalog, schemas.contains(saved.schema) {
                schema = saved.schema
            }
        } catch { if self.revision == revision { show(error) } }
    }

    func createSchema() async {
        guard canCreate, let client else { return }
        let catalog = catalog
        let name = normalizedNewSchemaName
        isCreating = true
        errorMessage = nil
        defer { isCreating = false }
        do {
            let created = try await client.createSchema(named: name, in: catalog)
            try Task.checkCancellation()
            schemas = Array(Set(schemas + [created])).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            schema = created
            newSchemaName = ""
            createdSchema = "\(catalog).\(created)"
        } catch { show(error) }
    }

    func save() async -> Bool {
        guard canSave, let client, let location = DatabricksCatalogSchema("\(catalog).\(schema)") else { return false }
        isSaving = true
        defer { isSaving = false }
        do {
            try await DatabricksCatalogSchema.save(location, connectionID: connectionID, repository: repository) { try client.validate() }
            savedLocation = location
            return true
        } catch {
            show(error)
            return false
        }
    }

    func clear() async -> Bool {
        guard !isCreating, !isSaving else { return false }
        isSaving = true
        defer { isSaving = false }
        do {
            try await DatabricksCatalogSchema.save(nil, connectionID: connectionID, repository: repository)
            savedLocation = nil
            return true
        } catch {
            show(error)
            return false
        }
    }

    private func show(_ error: any Error) {
        guard !Task.isCancelled else { return }
        errorMessage = error is CancellationError ? L10n.databricksCatalogAccountChanged : error.localizedDescription
    }
}
