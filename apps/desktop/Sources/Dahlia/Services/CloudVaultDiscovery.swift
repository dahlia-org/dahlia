import Foundation

enum CloudVaultDiscovery {
    @concurrent
    static func fetch(
        connection: DahliaAccountConnectionRecord,
        token: String,
        load: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }
    ) async throws -> [CloudVaultRecord] {
        struct Response: Decodable { let items: [Item] }
        struct Organization: Decodable { let id: String }
        struct Item: Decodable {
            let vaultId: UUID
            let name: String
            let revision: Int
            let createdAt: Date
            let role: String
        }

        guard let origin = URL(string: connection.origin) else { throw URLError(.badURL) }
        func request(_ path: String) throws -> URLRequest {
            guard let url = URL(string: path, relativeTo: origin)?.absoluteURL else { throw URLError(.badURL) }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            return request
        }
        let (personalData, personalResponse) = try await load(request("api/v1/vaults"))
        guard (personalResponse as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        var items = try SyncJSON.decoder.decode(Response.self, from: personalData).items
        let (organizationData, organizationResponse) = try await load(request("api/v1/organizations"))
        let status = (organizationResponse as? HTTPURLResponse)?.statusCode
        // Older Servers return all accessible Vaults and have no gateway organization listing.
        if status != 404 {
            guard status == 200 else { throw URLError(.badServerResponse) }
            let organizations = try SyncJSON.decoder.decode([Organization].self, from: organizationData)
            for organization in organizations {
                try Task.checkCancellation()
                var components = URLComponents()
                components.path = "api/v1/vaults"
                components.queryItems = [URLQueryItem(name: "organizationId", value: organization.id)]
                guard let path = components.string else { throw URLError(.badURL) }
                let (data, response) = try await load(request(path))
                let status = (response as? HTTPURLResponse)?.statusCode
                if status == 403 { continue } // Membership may have been revoked since listing.
                guard status == 200 else { throw URLError(.badServerResponse) }
                items += try SyncJSON.decoder.decode(Response.self, from: data).items
            }
        }
        var seen = Set<UUID>()
        return items.filter { seen.insert($0.vaultId).inserted }.map {
            CloudVaultRecord(
                vaultId: $0.vaultId,
                connectionId: connection.id,
                name: $0.name,
                createdAt: $0.createdAt,
                revision: $0.revision,
                role: $0.role
            )
        }
    }
}
