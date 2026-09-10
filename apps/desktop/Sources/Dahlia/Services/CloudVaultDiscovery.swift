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

    private static func fetch(connection: DahliaAccountConnectionRecord, client: DahliaServerAPI.Client) async throws -> [CloudVaultRecord] {
        let items = try await client.listVaults(query: .init(scope: .accessible)).ok.body.json.items
        var seen = Set<UUID>()
        return try items.compactMap { item -> CloudVaultRecord? in
            guard let vaultId = UUID(uuidString: item.vaultId) else { throw URLError(.cannotParseResponse) }
            guard seen.insert(vaultId).inserted else { return nil }
            return CloudVaultRecord(
                vaultId: vaultId,
                connectionId: connection.id,
                icon: item.icon, color: item.color,
                name: item.name,
                createdAt: item.createdAt,
                revision: item.revision,
                role: item.role?.rawValue ?? "member"
            )
        }
    }
}
