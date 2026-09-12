import DahliaServerAPI
import Foundation
import OpenAPIRuntime
import OpenAPIURLSession

enum CloudVaultDiscovery {
    @concurrent
    static func fetch(
        connection: DahliaAccountConnectionRecord,
        token: String,
        transport: any ClientTransport = URLSessionTransport()
    ) async throws -> [CloudVaultRecord] {
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

    static func fetch(connection: DahliaAccountConnectionRecord, apiClient: SyncAPIClient) async throws -> [CloudVaultRecord] {
        guard let origin = URL(string: connection.origin) else { throw URLError(.badURL) }
        return try await apiClient.perform(origin: origin, connectionId: connection.id, maximumBytes: 1024 * 1024) {
            try await fetch(connection: connection, client: $0)
        }
    }

    static func organizations(connection: DahliaAccountConnectionRecord, api: SyncAPIClient) async throws -> [Components.Schemas.Organization] {
        guard let origin = URL(string: connection.origin) else { throw URLError(.badURL) }
        return try await api.perform(origin: origin, connectionId: connection.id) { try await $0.listOrganizations().ok.body.json.items }
    }

    static func createOrganization(name: String, connection: DahliaAccountConnectionRecord, api: SyncAPIClient) async throws {
        guard let origin = URL(string: connection.origin) else { throw URLError(.badURL) }
        _ = try await api.perform(origin: origin, connectionId: connection.id) {
            try await $0.createOrganization(body: .json(.init(name: name, slug: "team-" + UUID.v7().uuidString.lowercased()))).created
        }
    }

    static func createVault(_ vault: VaultRecord, organizationId: UUID, connection: DahliaAccountConnectionRecord, api: SyncAPIClient) async throws {
        guard let origin = URL(string: connection.origin) else { throw URLError(.badURL) }
        var creating = vault
        creating.organizationId = organizationId
        let draft = try SyncInitialSnapshotBuilder.vaultOperation(creating, action: .create)
        guard let payloadJSON = draft.payloadJSON else { throw SyncTransactionQueueError.invalidReceipt }
        let payload = try JSONSerialization.jsonObject(with: payloadJSON)
        let data = try JSONSerialization.data(withJSONObject: [
            "id": UUID.v7().uuidString.lowercased(), "vaultId": vault.id.uuidString.lowercased(), "schemaVersion": 3,
            "createdAt": Date.now.ISO8601Format(),
            "operations": [[
                "id": draft.id.uuidString.lowercased(),
                "entity": "vault",
                "action": "create",
                "entityId": vault.id.uuidString.lowercased(),
                "baseRevision": NSNull(),
                "data": payload,
            ]],
        ], options: [.sortedKeys])
        let body = try SyncJSON.decoder.decode(Components.Schemas.Transaction.self, from: data)
        _ = try await api.perform(origin: origin, connectionId: connection.id, preservingJSONBody: data) {
            try await $0.commitTransaction(body: .json(body)).ok
        }
    }

    private static func fetch(connection: DahliaAccountConnectionRecord, client: DahliaServerAPI.Client) async throws -> [CloudVaultRecord] {
        let items = try await client.listVaults().ok.body.json.items
        var seen = Set<UUID>()
        return try items.compactMap { item -> CloudVaultRecord? in
            guard let vaultId = UUID(uuidString: item.vaultId),
                  let organizationId = UUID(uuidString: item.organizationId) else { throw URLError(.cannotParseResponse) }
            guard seen.insert(vaultId).inserted else { return nil }
            return CloudVaultRecord(
                vaultId: vaultId,
                connectionId: connection.id,
                organizationId: organizationId,
                icon: item.icon, color: item.color,
                name: item.name,
                createdAt: item.createdAt,
                revision: item.revision,
                role: item.role.rawValue
            )
        }
    }
}
