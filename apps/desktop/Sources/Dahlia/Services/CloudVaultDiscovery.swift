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
        var items = try await client.listVaults().ok.body.json.items
        let organizations = try await client.listOrganizations().ok.body.json.items
        for organization in organizations {
            try Task.checkCancellation()
            do {
                items += try await client.listVaults(query: .init(organizationId: organization.id)).ok.body.json.items
            } catch {
                let underlying = (error as? ClientError)?.underlyingError ?? error
                if (underlying as? SyncHTTPError)?.status == 403 { continue }
                throw underlying
            }
        }
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
