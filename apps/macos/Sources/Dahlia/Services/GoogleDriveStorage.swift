import Foundation

/// Google Drive under the configured app-created folder in My Drive. With the `drive.file` scope Dahlia sees only the folders and files it created,
/// so a folder the user made by hand with the same name never mixes in.
struct GoogleDriveStorage: ProviderStorage {
    static let rootFolderName = GoogleDriveStorageLocation.defaultFolderName
    private let folderName: String
    private static let folderMimeType = "application/vnd.google-apps.folder"
    private let http: ProviderStorageHTTP
    private let baseURL: URL
    private let validateContext: @Sendable () async throws -> Void

    init(
        folderName: String = Self.rootFolderName,
        baseURL: URL = GoogleCalendarAPIClient.googleAPIBaseURL,
        session: URLSession = .shared,
        validate: @escaping @Sendable () async throws -> Void = { try Task.checkCancellation() },
        accessToken: @escaping @Sendable () async throws -> String
    ) {
        self.folderName = folderName
        self.baseURL = baseURL
        validateContext = validate
        http = ProviderStorageHTTP(session: session, accessToken: accessToken)
    }

    @MainActor
    init(
        accountID: UUID,
        signIn: any GoogleSignInProviding,
        repository: MeetingRepository? = nil,
        baseURL: URL = GoogleCalendarAPIClient.googleAPIBaseURL,
        session: URLSession = .shared
    ) async throws {
        let generation = GoogleSignInAdapter.storageGeneration(accountID: accountID)
        let location = try await GoogleDriveStorageLocation.load(accountID: accountID, repository: repository)
        let validate: @MainActor @Sendable () async throws -> Void = {
            guard try await GoogleDriveStorageLocation.load(accountID: accountID, repository: repository) == location else {
                throw CancellationError()
            }
            try GoogleSignInAdapter.validateStorageGeneration(generation, accountID: accountID)
            guard !signIn.isDisconnectPending else { throw CancellationError() }
        }
        self.init(folderName: location.folderName, baseURL: baseURL, session: session, validate: validate) { @MainActor in
            // A pre-drive.file grant is insufficient, even when its retired read scope remains stored.
            guard let current = try await signIn.refreshCurrentSession(), current.hasScopes(GoogleOAuthScope.drive) else {
                throw ProviderStorageError.authorizationRequired
            }
            try await validate()
            return current.accessToken
        }
    }

    func validate() async throws { try await validateContext() }

    func list(directory: String) async throws -> [ProviderStorageFile] {
        guard let folder = try await folder(directory, create: false) else { return [] }
        return try await files(matching: "'\(folder)' in parents and mimeType != '\(Self.folderMimeType)'")
            .sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
    }

    /// One resumable session sent in a single request; a failure starts over from the beginning.
    func upload(_ file: URL, to directory: String, name: String) async throws {
        guard let folder = try await folder(directory, create: true) else { throw ProviderStorageError.invalidResponse }
        struct Metadata: Encodable {
            let name: String
            let parents: [String]
        }
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        var start = try ProviderStorageHTTP.jsonRequest(
            url("upload/drive/v3/files", query: ["uploadType": "resumable", "fields": "id"]),
            method: "POST",
            body: Metadata(name: name, parents: [folder])
        )
        start.setValue("application/gzip", forHTTPHeaderField: "X-Upload-Content-Type")
        start.setValue(String(size), forHTTPHeaderField: "X-Upload-Content-Length")
        let (_, response) = try await http.data(start)
        guard let location = response.value(forHTTPHeaderField: "Location").flatMap(URL.init(string:)) else {
            throw ProviderStorageError.invalidResponse
        }
        var request = URLRequest(url: location)
        request.httpMethod = "PUT"
        request.setValue("application/gzip", forHTTPHeaderField: "Content-Type")
        _ = try await http.upload(request, fromFile: file)
    }

    func download(_ file: ProviderStorageFile) async throws -> URL {
        guard Self.isFileID(file.id) else { throw ProviderStorageError.invalidResponse }
        return try await http.download(URLRequest(url: url("drive/v3/files/\(file.id)", query: ["alt": "media"])))
    }

    /// Moves the file to the Drive trash, where the user can still restore it.
    func delete(_ file: ProviderStorageFile) async throws {
        guard Self.isFileID(file.id) else { throw ProviderStorageError.invalidResponse }
        struct Trash: Encodable { let trashed = true }
        _ = try await http.data(ProviderStorageHTTP.jsonRequest(url("drive/v3/files/\(file.id)", query: [:]), method: "PATCH", body: Trash()))
    }

    /// The folder `My Drive/<configured folder>/<directory>`; nil when it does not exist and `create` is false.
    private func folder(_ directory: String, create: Bool) async throws -> String? {
        var parent = "root"
        for name in [folderName, directory] {
            let folders = try await files(
                matching: "'\(parent)' in parents and name = '\(Self.escaped(name))' and mimeType = '\(Self.folderMimeType)'"
            )
            // Two Macs creating the first folder at once can leave duplicates; the user merges them in Drive.
            guard folders.count <= 1 else { throw ProviderStorageError.ambiguousFolder }
            if let folder = folders.first {
                parent = folder.id
                continue
            }
            guard create else { return nil }
            parent = try await createFolder(name, in: parent)
        }
        return parent
    }

    private func createFolder(_ name: String, in parent: String) async throws -> String {
        struct Folder: Encodable {
            let name: String
            let mimeType = GoogleDriveStorage.folderMimeType
            let parents: [String]
        }
        struct Created: Decodable { let id: String }
        let (data, _) = try await http.data(ProviderStorageHTTP.jsonRequest(
            url("drive/v3/files", query: ["fields": "id"]), method: "POST", body: Folder(name: name, parents: [parent])
        ))
        let id = try JSONDecoder().decode(Created.self, from: data).id
        guard Self.isFileID(id) else { throw ProviderStorageError.invalidResponse }
        return id
    }

    private func files(matching query: String) async throws -> [ProviderStorageFile] {
        struct Page: Decodable {
            struct File: Decodable {
                let id: String
                let name: String
                let size: String?
                let modifiedTime: String?
            }

            let files: [File]
            let nextPageToken: String?
        }
        var files: [ProviderStorageFile] = []
        var token: String?
        repeat {
            try Task.checkCancellation()
            var parameters = [
                "q": query + " and trashed = false",
                "spaces": "drive",
                "corpora": "user",
                "fields": "nextPageToken,files(id,name,size,modifiedTime)",
                "pageSize": "1000",
            ]
            parameters["pageToken"] = token
            let (data, _) = try await http.data(URLRequest(url: url("drive/v3/files", query: parameters)))
            let page = try JSONDecoder().decode(Page.self, from: data)
            guard page.files.allSatisfy({ Self.isFileID($0.id) }) else { throw ProviderStorageError.invalidResponse }
            files += page.files.map {
                ProviderStorageFile(
                    id: $0.id, name: $0.name, size: $0.size.flatMap(Int64.init),
                    modifiedAt: $0.modifiedTime.flatMap { try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse($0) }
                )
            }
            token = page.nextPageToken
        } while token != nil
        return files
    }

    private func url(_ path: String, query: [String: String]) -> URL {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        components.queryItems = query.isEmpty ? nil : query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        // Drive decodes form queries, where a raw plus represents a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }

    private static func escaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
    }

    /// Drive IDs go into URL paths and queries, so only their known alphabet is accepted.
    private static func isFileID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8
            .allSatisfy { (48 ... 57).contains($0) || (65 ... 90).contains($0) || (97 ... 122).contains($0) || $0 == 45 || $0 == 95 }
    }
}
