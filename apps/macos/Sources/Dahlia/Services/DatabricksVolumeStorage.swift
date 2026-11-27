import Foundation

/// The `catalog.schema` a Databricks connection keeps its storage volume in, saved per connection on this Mac.
struct DatabricksStorageLocation: Equatable, Sendable, CustomStringConvertible {
    let catalog: String
    let schema: String

    /// Exactly two non-empty names separated by one dot. The names become URL path components, so separators,
    /// quoting, and whitespace are rejected.
    init?(_ value: String) {
        let parts = value.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ part in
            !part.isEmpty && !part.contains { $0.isWhitespace || "/`\\".contains($0) }
        }) else { return nil }
        catalog = String(parts[0])
        schema = String(parts[1])
    }

    var description: String { "\(catalog).\(schema)" }

    static func key(for connectionID: UUID) -> String { "providerStorageSchema.\(connectionID.uuidString)" }

    static func load(connectionID: UUID, defaults: UserDefaults = .standard) -> Self? {
        defaults.string(forKey: key(for: connectionID)).flatMap(Self.init)
    }

    static func save(_ location: Self?, connectionID: UUID, defaults: UserDefaults = .standard) {
        guard load(connectionID: connectionID, defaults: defaults) != location else { return }
        defaults.set(location?.description, forKey: key(for: connectionID))
        NotificationCenter.default.post(name: didChange(connectionID: connectionID), object: nil)
    }

    static func didChange(connectionID: UUID) -> Notification.Name {
        Notification.Name("DatabricksStorageLocation.\(connectionID.uuidString)")
    }
}

/// The signed-in user's managed volume `<catalog>.<schema>.dahlia_storage_<user ID>`, through Files API 2.0. Dahlia
/// uses an existing volume only when the user owns it, since anyone can create one with that name first.
actor DatabricksVolumeStorage: ProviderStorage {
    /// Files API 2.0 accepts one upload of up to 5000 MiB (docs.databricks.com, checked 2026-11-27).
    static let uploadLimit: Int64 = 5000 * 1024 * 1024
    private static let decoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    private static let encoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }()

    private let host: URL
    private let location: DatabricksStorageLocation
    private let http: ProviderStorageHTTP
    /// Verified only within this operation's fixed authorization context.
    private var root: String?

    init(
        host: URL,
        location: DatabricksStorageLocation,
        session: URLSession = .shared,
        authorization: ProviderStorageAuthorization,
        validateLocation: @escaping @Sendable () async throws -> Void = {}
    ) {
        self.host = host
        self.location = location
        http = ProviderStorageHTTP(session: session) {
            try await authorization.validate()
            try await validateLocation()
            return authorization.accessToken
        }
    }

    func list(directory: String) async throws -> [ProviderStorageFile] {
        guard let root = try await volumeRoot(create: false) else { return [] }
        struct Page: Decodable {
            struct Entry: Decodable {
                let path: String
                let isDirectory: Bool?
                let fileSize: Int64?
                let lastModified: Int64?
            }

            let contents: [Entry]?
            let nextPageToken: String?
        }
        let directoryPath = "\(root)/\(directory)"
        var files: [ProviderStorageFile] = []
        var token: String?
        repeat {
            try Task.checkCancellation()
            let (data, response) = try await http.data(
                URLRequest(url: url("api/2.0/fs/directories", path: directoryPath, query: ["page_token": token])),
                allowing: [404]
            )
            guard response.statusCode != 404 else { return [] }
            let page = try Self.decoder.decode(Page.self, from: data)
            files += (page.contents ?? []).filter { $0.isDirectory != true && $0.path.hasPrefix(directoryPath + "/") }.map {
                ProviderStorageFile(
                    id: $0.path, name: ($0.path as NSString).lastPathComponent, size: $0.fileSize,
                    modifiedAt: $0.lastModified.map { Date(timeIntervalSince1970: Double($0) / 1000) }
                )
            }
            token = page.nextPageToken
        } while token != nil
        return files.sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
    }

    func validate() async throws { _ = try await http.accessToken() }

    func upload(_ file: URL, to directory: String, name: String) async throws {
        let size = try Int64(file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        guard size <= Self.uploadLimit else { throw ProviderStorageError.fileTooLarge }
        guard let root = try await volumeRoot(create: true) else { throw ProviderStorageError.invalidResponse }
        var directoryRequest = URLRequest(url: url("api/2.0/fs/directories", path: "\(root)/\(directory)"))
        directoryRequest.httpMethod = "PUT"
        _ = try await http.data(directoryRequest)
        var request = URLRequest(url: url("api/2.0/fs/files", path: "\(root)/\(directory)/\(name)", query: ["overwrite": "false"]))
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        _ = try await http.upload(request, fromFile: file)
    }

    func download(_ file: ProviderStorageFile) async throws -> URL {
        try await http.download(URLRequest(url: url("api/2.0/fs/files", path: verifiedPath(file))))
    }

    func delete(_ file: ProviderStorageFile) async throws {
        var request = try await URLRequest(url: url("api/2.0/fs/files", path: verifiedPath(file)))
        request.httpMethod = "DELETE"
        _ = try await http.data(request)
    }

    /// The volume name for a SCIM user ID. Only its digits are used; an ID shaped `<user>@<account>` keeps the part
    /// before `@`. Anything else is rejected rather than put into a volume name.
    static func volumeName(userID: String) throws -> String {
        let digits = userID.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { throw ProviderStorageError.unsupportedUserID }
        return "dahlia_storage_\(digits)"
    }

    /// A listed file's path, which must lie inside this volume.
    private func verifiedPath(_ file: ProviderStorageFile) async throws -> String {
        guard let root = try await volumeRoot(create: false), file.id.hasPrefix(root + "/"),
              !file.id.split(separator: "/").contains("..") else { throw ProviderStorageError.invalidResponse }
        return file.id
    }

    private struct VolumeInfo: Decodable {
        let owner: String?
        let volumeType: String?
    }

    /// Finds the user's volume, creating it when `create` is true. Nil means it does not exist yet.
    private func volumeRoot(create: Bool) async throws -> String? {
        if let root { return root }
        struct SCIMUser: Decodable {
            let id: String
            let userName: String
        }
        let (meData, _) = try await http.data(URLRequest(url: host.appending(path: "api/2.0/preview/scim/v2/Me")))
        let me = try JSONDecoder().decode(SCIMUser.self, from: meData)
        let name = try Self.volumeName(userID: me.id)
        let fullName = "\(location.catalog).\(location.schema).\(name)"
        var volume = try await fetchVolume(fullName)
        if volume == nil {
            guard create else { return nil }
            volume = try await createVolume(name: name, owner: me.userName)
            if volume == nil { volume = try await fetchVolume(fullName) }
        }
        guard let volume else { throw ProviderStorageError.invalidResponse }
        guard volume.owner?.lowercased() == me.userName.lowercased(), volume.volumeType == "MANAGED" else {
            throw ProviderStorageError.volumeNotOwned(volume: fullName, owner: volume.owner ?? "")
        }
        let root = "/Volumes/\(location.catalog)/\(location.schema)/\(name)"
        self.root = root
        return root
    }

    private func fetchVolume(_ fullName: String) async throws -> VolumeInfo? {
        let (data, response) = try await http.data(
            URLRequest(url: host.appending(path: "api/2.1/unity-catalog/volumes").appending(path: fullName)),
            allowing: [404]
        )
        return response.statusCode == 404 ? nil : try Self.decoder.decode(VolumeInfo.self, from: data)
    }

    /// Nil when another Mac created it at the same moment (409), so the caller reads it instead.
    private func createVolume(name: String, owner: String) async throws -> VolumeInfo? {
        struct Create: Encodable {
            let catalogName: String
            let schemaName: String
            let name: String
            let volumeType = "MANAGED"
            let comment: String
        }
        let (data, response) = try await http.data(
            ProviderStorageHTTP.jsonRequest(
                host.appending(path: "api/2.1/unity-catalog/volumes"),
                method: "POST",
                body: Create(
                    catalogName: location.catalog, schemaName: location.schema, name: name, comment: "Dahlia storage for \(owner)"
                ),
                encoder: Self.encoder
            ),
            allowing: [409]
        )
        return response.statusCode == 409 ? nil : try Self.decoder.decode(VolumeInfo.self, from: data)
    }

    private func url(_ endpoint: String, path: String, query: [String: String?] = [:]) -> URL {
        var components = URLComponents(
            url: host.appending(path: endpoint).appending(path: String(path.drop { $0 == "/" })),
            resolvingAgainstBaseURL: false
        )!
        let items = query.compactMap { key, value in value.map { URLQueryItem(name: key, value: $0) } }
        components.queryItems = items.isEmpty ? nil : items
        return components.url!
    }
}
