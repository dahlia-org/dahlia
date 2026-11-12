import Foundation

struct GoogleDriveBackupFile: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let size: String?
    let modifiedTime: String?
}

/// Read-only Drive access. Uploads, folder creation, and deletion belong to Pi's MCP server.
struct GoogleDriveBackupClient: Sendable {
    private let urlSession: URLSession

    init(urlSession: URLSession = .shared) { self.urlSession = urlSession }

    @concurrent
    func fetchAccount(session: GoogleSession) async throws -> GoogleCalendarAccount {
        struct About: Decodable {
            struct User: Decodable { let displayName: String
                let emailAddress: String
                let permissionId: String
            }

            let user: User
        }
        let data = try await get(
            "about",
            query: [URLQueryItem(name: "fields", value: "user(displayName,emailAddress,permissionId)")],
            session: session
        )
        let user = try JSONDecoder().decode(About.self, from: data).user
        return GoogleCalendarAccount(id: user.permissionId, displayName: user.displayName, email: user.emailAddress)
    }

    @concurrent
    func listBackups(session: GoogleSession) async throws -> [GoogleDriveBackupFile] {
        var parent = "root"
        for name in ["Dahlia", "Backup"] {
            let folders = try await list(
                query: "'\(parent)' in parents and name = '\(name)' and mimeType = 'application/vnd.google-apps.folder'",
                session: session
            )
            guard folders.count <= 1 else { throw GoogleDriveBackupError.ambiguousFolder }
            guard let folder = folders.first else { return [] }
            parent = folder.id
        }
        return try await list(query: "'\(Self.escaped(parent))' in parents and mimeType != 'application/vnd.google-apps.folder'", session: session)
            .filter { BackupArchive.isBackupFile(URL(fileURLWithPath: $0.name)) }
            .sorted { ($0.modifiedTime ?? "") > ($1.modifiedTime ?? "") }
    }

    @concurrent
    func download(_ file: GoogleDriveBackupFile, session: GoogleSession) async throws -> URL {
        guard Self.isFileID(file.id) else { throw BackupServiceError.invalidBackup }
        let url = session.apiBaseURL.appending(path: "drive/v3/files/\(file.id)")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "alt", value: "media")]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        let (download, response) = try await urlSession.download(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            try? FileManager.default.removeItem(at: download)
            throw GoogleDriveBackupError.downloadFailed
        }
        return download
    }

    private func list(query: String, session: GoogleSession) async throws -> [GoogleDriveBackupFile] {
        struct Page: Decodable { let files: [GoogleDriveBackupFile]
            let nextPageToken: String?
        }
        var files: [GoogleDriveBackupFile] = []
        var token: String?
        repeat {
            try Task.checkCancellation()
            let data = try await get("files", query: [
                URLQueryItem(name: "q", value: query + " and trashed = false"),
                URLQueryItem(name: "spaces", value: "drive"),
                URLQueryItem(name: "corpora", value: "user"),
                URLQueryItem(name: "fields", value: "nextPageToken,files(id,name,size,modifiedTime)"),
                URLQueryItem(name: "pageSize", value: "1000"),
            ] + (token.map { [URLQueryItem(name: "pageToken", value: $0)] } ?? []), session: session)
            let page = try JSONDecoder().decode(Page.self, from: data)
            guard page.files.allSatisfy({ Self.isFileID($0.id) }) else { throw BackupServiceError.invalidBackup }
            files += page.files
            token = page.nextPageToken
        } while token != nil
        return files
    }

    private func get(_ path: String, query: [URLQueryItem], session: GoogleSession) async throws -> Data {
        var components = URLComponents(url: session.apiBaseURL.appending(path: "drive/v3/\(path)"), resolvingAgainstBaseURL: false)!
        components.queryItems = query
        return try await GoogleCalendarAPIClient.authorizedGet(url: components.url!, accessToken: session.accessToken, session: urlSession)
    }

    private static func escaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
    }

    private static func isFileID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8
            .allSatisfy { (48 ... 57).contains($0) || (65 ... 90).contains($0) || (97 ... 122).contains($0) || $0 == 45 || $0 == 95 }
    }
}

enum GoogleDriveBackupError: LocalizedError, Equatable {
    case ambiguousFolder
    case downloadFailed

    var errorDescription: String? {
        switch self {
        case .ambiguousFolder: L10n.backupDriveAmbiguousFolder
        case .downloadFailed: L10n.backupDriveDownloadFailed
        }
    }
}
