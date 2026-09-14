import DahliaServerAPI
import Foundation
import OpenAPIRuntime
import OpenAPIURLSession

struct CloudOrganizationDirectory: Sendable {
    var items: [Components.Schemas.Organization]
    var canCreateOrganizations: Bool
}

struct CloudOrganizationOwner: Identifiable, Sendable {
    let id: String
    let name: String
    let email: String
}

enum CloudWorkspaceDiscovery {
    @concurrent
    static func fetch(
        connection: DahliaAccountConnectionRecord,
        token: String,
        transport: any ClientTransport = URLSessionTransport()
    ) async throws -> [CloudWorkspaceRecord] {
        guard let origin = URL(string: connection.origin) else { throw URLError(.badURL) }
        let client = DahliaServerAPI.Client(
            serverURL: origin,
            configuration: .init(dateTranscoder: SyncAPIDateTranscoder()),
            transport: transport,
            middlewares: [SyncAPIMiddleware(
                token: token,
                maximumBytes: 1024 * 1024,
                preservingJSONBody: nil,
                capture: nil
            )]
        )
        return try await fetch(connection: connection, client: client)
    }

    static func fetch(connection: DahliaAccountConnectionRecord, apiClient: SyncAPIClient) async throws -> [CloudWorkspaceRecord] {
        guard let origin = URL(string: connection.origin) else { throw URLError(.badURL) }
        return try await apiClient.perform(origin: origin, connectionId: connection.id, maximumBytes: 1024 * 1024) {
            try await fetch(connection: connection, client: $0)
        }
    }

    static func organizations(connection: DahliaAccountConnectionRecord, api: SyncAPIClient) async throws -> CloudOrganizationDirectory {
        guard let origin = URL(string: connection.origin) else { throw URLError(.badURL) }
        return try await api.perform(origin: origin, connectionId: connection.id) {
            let page = try await $0.listOrganizations().ok.body.json
            return CloudOrganizationDirectory(items: page.items, canCreateOrganizations: page.canCreateOrganizations)
        }
    }

    static func organizationOwners(
        connection: DahliaAccountConnectionRecord,
        api: SyncAPIClient,
        offset: Int
    ) async throws -> (items: [CloudOrganizationOwner], hasMore: Bool) {
        guard let origin = URL(string: connection.origin) else { throw URLError(.badURL) }
        return try await api.perform(origin: origin, connectionId: connection.id) {
            let page = try await $0.listServerUsers(query: .init(offset: String(offset))).ok.body.json
            return (page.items.map { CloudOrganizationOwner(id: $0.value1.id, name: $0.value1.name, email: $0.value1.email) }, page.hasMore)
        }
    }

    static func createOrganization(
        name: String,
        slug: String,
        initialOwnerUserId: String,
        connection: DahliaAccountConnectionRecord,
        api: SyncAPIClient
    ) async throws {
        guard let origin = URL(string: connection.origin) else { throw URLError(.badURL) }
        _ = try await api.perform(origin: origin, connectionId: connection.id) {
            try await $0.createOrganization(body: .json(.init(name: name, slug: slug, initialOwnerUserId: initialOwnerUserId))).created
        }
    }

    static func createWorkspace(
        _ workspace: WorkspaceRecord,
        organizationId: UUID,
        connection: DahliaAccountConnectionRecord,
        api: SyncAPIClient
    ) async throws {
        guard let origin = URL(string: connection.origin) else { throw URLError(.badURL) }
        var creating = workspace
        creating.organizationId = organizationId
        let draft = try SyncInitialSnapshotBuilder.workspaceOperation(creating, action: .create)
        guard let payloadJSON = draft.payloadJSON else { throw SyncTransactionQueueError.invalidReceipt }
        let payload = try JSONSerialization.jsonObject(with: payloadJSON)
        let data = try JSONSerialization.data(withJSONObject: [
            "id": UUID.v7().uuidString.lowercased(), "workspaceId": workspace.id.uuidString.lowercased(), "schemaVersion": 3,
            "createdAt": Date.now.ISO8601Format(),
            "operations": [[
                "id": draft.id.uuidString.lowercased(),
                "entity": "workspace",
                "action": "create",
                "entityId": workspace.id.uuidString.lowercased(),
                "baseRevision": NSNull(),
                "data": payload,
            ]],
        ], options: [.sortedKeys])
        let body = try SyncJSON.decoder.decode(Components.Schemas.Transaction.self, from: data)
        _ = try await api.perform(origin: origin, connectionId: connection.id, preservingJSONBody: data) {
            try await $0.commitTransaction(body: .json(body)).ok
        }
    }

    private static func fetch(connection: DahliaAccountConnectionRecord, client: DahliaServerAPI.Client) async throws -> [CloudWorkspaceRecord] {
        let items = try await client.listWorkspaces().ok.body.json.items
        var seen = Set<UUID>()
        return try items.compactMap { item -> CloudWorkspaceRecord? in
            guard let workspaceId = UUID(uuidString: item.workspaceId),
                  let organizationId = UUID(uuidString: item.organizationId) else { throw URLError(.cannotParseResponse) }
            guard seen.insert(workspaceId).inserted else { return nil }
            return try CloudWorkspaceRecord(
                workspaceId: workspaceId,
                connectionId: connection.id,
                organizationId: organizationId,
                icon: item.icon, color: item.color,
                name: item.name,
                createdAt: item.createdAt,
                revision: item.revision,
                role: item.role.rawValue,
                generationSettings: JSONDecoder().decode(WorkspaceGenerationSettings.self, from: JSONEncoder().encode(item.generationSettings))
            )
        }
    }
}
