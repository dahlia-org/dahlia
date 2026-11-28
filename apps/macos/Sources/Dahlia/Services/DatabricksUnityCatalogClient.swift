import Foundation

protocol DatabricksUnityCatalogProviding: Sendable {
    func validate() throws
    func catalogs() async throws -> [String]
    func schemas(in catalog: String) async throws -> [String]
    func createSchema(named name: String, in catalog: String) async throws -> String
}

/// Unity Catalog metadata for a single provider account and sign-in, independent of the consuming feature.
struct DatabricksUnityCatalogClient: DatabricksUnityCatalogProviding {
    private let host: URL
    private let http: ProviderStorageHTTP
    private let authorization: ProviderStorageAuthorization

    init(host: URL, session: URLSession = .shared, authorization: ProviderStorageAuthorization) {
        self.host = host
        self.authorization = authorization
        http = ProviderStorageHTTP(session: session) {
            try authorization.validate()
            return authorization.accessToken
        }
    }

    func validate() throws { try authorization.validate() }

    func catalogs() async throws -> [String] { try await names("catalogs") }

    func schemas(in catalog: String) async throws -> [String] {
        try await names("schemas", query: ["catalog_name": catalog])
    }

    func createSchema(named name: String, in catalog: String) async throws -> String {
        guard DatabricksCatalogSchema("\(catalog).\(name)") != nil else { throw URLError(.badURL) }
        struct Create: Encodable {
            let name: String
            let catalogName: String

            enum CodingKeys: String, CodingKey {
                case name
                case catalogName = "catalog_name"
            }
        }
        let request = try ProviderStorageHTTP.jsonRequest(
            url("schemas"), method: "POST", body: Create(name: name, catalogName: catalog)
        )
        let (data, _) = try await http.data(request)
        try validate()
        let created = try JSONDecoder().decode(Entry.self, from: data)
        guard created.catalogName == catalog, DatabricksCatalogSchema("\(catalog).\(created.name)") != nil else {
            throw ProviderStorageError.invalidResponse
        }
        return created.name
    }

    private struct Entry: Decodable {
        let name: String
        let catalogName: String?

        enum CodingKeys: String, CodingKey {
            case name
            case catalogName = "catalog_name"
        }
    }

    private struct Page: Decodable {
        let catalogs: [Entry]?
        let schemas: [Entry]?
        let nextPageToken: String?

        enum CodingKeys: String, CodingKey {
            case catalogs, schemas
            case nextPageToken = "next_page_token"
        }
    }

    private func names(_ endpoint: String, query: [String: String] = [:]) async throws -> [String] {
        var result: [String] = []
        var parameters = query.merging(["max_results": "0", "include_browse": "false"]) { first, _ in first }
        var visited = Set<String>()
        repeat {
            let (data, _) = try await http.data(URLRequest(url: url(endpoint, query: parameters)))
            try validate()
            let page = try JSONDecoder().decode(Page.self, from: data)
            let entries = endpoint == "catalogs" ? page.catalogs ?? [] : page.schemas ?? []
            guard entries.allSatisfy({ DatabricksCatalogSchema.isValidName($0.name) }),
                  entries.allSatisfy({ $0.catalogName == nil || $0.catalogName == query["catalog_name"] }) else {
                throw ProviderStorageError.invalidResponse
            }
            result += entries.map(\.name)
            parameters["page_token"] = page.nextPageToken?.nilIfBlank
            if let token = parameters["page_token"], !visited.insert(token).inserted {
                throw ProviderStorageError.invalidResponse
            }
        } while parameters["page_token"] != nil
        return Array(Set(result)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private func url(_ endpoint: String, query: [String: String] = [:]) -> URL {
        var components = URLComponents(url: host.appending(path: "api/2.1/unity-catalog/\(endpoint)"), resolvingAgainstBaseURL: false)!
        components.queryItems = query.isEmpty ? nil : query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.url!
    }
}
