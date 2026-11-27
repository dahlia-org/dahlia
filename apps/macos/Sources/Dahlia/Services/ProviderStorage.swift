import Foundation

/// A provider account's file storage. A directory is one folder name under Dahlia's root there: `My Drive/Dahlia` on
/// Google Drive, the user's volume on Databricks. Backups use `backup`.
protocol ProviderStorage: Sendable {
    func validate() async throws
    func list(directory: String) async throws -> [ProviderStorageFile]
    func upload(_ file: URL, to directory: String, name: String) async throws
    /// Downloads to a temporary file the caller removes.
    func download(_ file: ProviderStorageFile) async throws -> URL
    func delete(_ file: ProviderStorageFile) async throws
}

extension ProviderStorage {
    func validate() async throws { try Task.checkCancellation() }
}

struct ProviderStorageFile: Identifiable, Equatable, Sendable {
    /// Opaque to callers: a Drive file ID or a volume path. Two files may share a name, never an ID.
    let id: String
    let name: String
    let size: Int64?
    let modifiedAt: Date?
}

/// One operation's fixed bearer and the source owner's check that its sign-in is still current.
struct ProviderStorageAuthorization: Sendable {
    let accessToken: String
    let validate: @Sendable () async throws -> Void
}

enum ProviderStorageError: LocalizedError, Equatable {
    case authorizationRequired
    case ambiguousFolder
    case fileTooLarge
    case schemaNotConfigured
    case unsupportedUserID
    case volumeNotOwned(volume: String, owner: String)
    case requestFailed(statusCode: Int, message: String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .authorizationRequired: L10n.backupStorageAuthorizationRequired
        case .ambiguousFolder: L10n.backupDriveAmbiguousFolder
        case .fileTooLarge: L10n.backupStorageFileTooLarge
        case .schemaNotConfigured: L10n.backupStorageSchemaNotConfigured
        case .unsupportedUserID: L10n.backupStorageUnsupportedUserID
        case let .volumeNotOwned(volume, owner): L10n.backupStorageVolumeNotOwned(volume, owner)
        case let .requestFailed(statusCode, message): L10n.backupStorageRequestFailed(statusCode, message)
        case .invalidResponse: L10n.backupStorageInvalidResponse
        }
    }
}

/// The HTTP plumbing both storages share: a bearer token per request and 2xx checking.
struct ProviderStorageHTTP: Sendable {
    let session: URLSession
    let accessToken: @Sendable () async throws -> String

    func data(_ request: URLRequest, allowing allowed: Set<Int> = []) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: authorized(request))
        return try (data, check(response, body: data, allowing: allowed))
    }

    func upload(_ request: URLRequest, fromFile file: URL) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.upload(for: authorized(request), fromFile: file)
        return try (data, check(response, body: data))
    }

    func download(_ request: URLRequest) async throws -> URL {
        let (url, response) = try await session.download(for: authorized(request))
        do {
            guard let http = response as? HTTPURLResponse else { throw ProviderStorageError.invalidResponse }
            guard (200 ... 299).contains(http.statusCode) else {
                // An error body is small; a successful archive may not fit in memory, so only failures are read.
                let body = (try? FileHandle(forReadingFrom: url)).flatMap { try? $0.read(upToCount: 64 * 1024) } ?? Data()
                throw Self.failure(statusCode: http.statusCode, body: body)
            }
            return url
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    private func authorized(_ request: URLRequest) async throws -> URLRequest {
        try Task.checkCancellation()
        let token = try await accessToken()
        try Task.checkCancellation()
        var request = request
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func check(_ response: URLResponse, body: Data, allowing allowed: Set<Int> = []) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else { throw ProviderStorageError.invalidResponse }
        guard (200 ... 299).contains(http.statusCode) || allowed.contains(http.statusCode) else {
            throw Self.failure(statusCode: http.statusCode, body: body)
        }
        return http
    }

    /// Google nests the message under `error`; Databricks puts it at the top level.
    static func failure(statusCode: Int, body: Data) -> ProviderStorageError {
        struct Body: Decodable {
            struct Nested: Decodable { let message: String? }
            let message: String?
            let error: Nested?
        }
        let decoded = try? JSONDecoder().decode(Body.self, from: body)
        let message = decoded?.message ?? decoded?.error?.message ?? String(decoding: body.prefix(300), as: UTF8.self)
        return .requestFailed(statusCode: statusCode, message: message)
    }

    static func jsonRequest(_ url: URL, method: String, body: some Encodable, encoder: JSONEncoder = JSONEncoder()) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)
        return request
    }
}
