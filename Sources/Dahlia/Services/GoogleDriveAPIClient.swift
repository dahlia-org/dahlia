import Foundation

protocol GoogleDriveAPIClientProviding: AnyObject, Sendable {
    func searchFolders(accessToken: String, query: String) async throws -> [GoogleDriveFolderItem]
    func listFolders(accessToken: String, parentFolderId: String?, driveId: String?) async throws -> [GoogleDriveFolderItem]
    func listRecentFolders(accessToken: String) async throws -> [GoogleDriveFolderItem]
    func listSharedDrives(accessToken: String) async throws -> [GoogleDriveFolderItem]
    func fetchFolder(accessToken: String, id: String) async throws -> GoogleDriveFolderItem
    func upsertGoogleDocument(
        accessToken: String,
        parentFolderId: String,
        fileName: String,
        content: String,
        appProperties: [String: String]
    ) async throws -> String
}

enum GoogleDriveAPIError: LocalizedError {
    case invalidResponse
    case httpError(statusCode: Int, detail: String)
    case folderNotFound

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            L10n.googleDriveUnexpectedResponse
        case let .httpError(statusCode, detail):
            L10n.googleDriveHTTPError(statusCode, detail)
        case .folderNotFound:
            L10n.googleDriveFolderUnavailable
        }
    }
}

final class GoogleDriveAPIClient: GoogleDriveAPIClientProviding, @unchecked Sendable {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func searchFolders(accessToken: String, query: String) async throws -> [GoogleDriveFolderItem] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var predicates = [
            "mimeType = 'application/vnd.google-apps.folder'",
            "trashed = false",
        ]
        if !trimmedQuery.isEmpty {
            let escapedQuery = Self.escapeQueryLiteral(trimmedQuery)
            predicates.append("name contains '\(escapedQuery)'")
        }
        let payload = try await listFiles(
            accessToken: accessToken,
            query: predicates.joined(separator: " and "),
            fields: "files(id,name,driveId,parents,mimeType)"
        )
        return try await enrichFolders(payload.files, accessToken: accessToken)
    }

    func listFolders(accessToken: String, parentFolderId: String?, driveId: String?) async throws -> [GoogleDriveFolderItem] {
        let parentID = (parentFolderId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? parentFolderId! : "root"
        let escapedParentID = Self.escapeQueryLiteral(parentID)
        let payload = try await listFiles(
            accessToken: accessToken,
            query: """
            mimeType = 'application/vnd.google-apps.folder' and trashed = false and '\(escapedParentID)' in parents
            """,
            fields: "files(id,name,driveId,parents,mimeType)",
            corpora: driveId == nil ? "user" : "drive",
            driveId: driveId,
            includeItemsFromAllDrives: driveId != nil
        )
        return try await enrichFolders(payload.files, accessToken: accessToken)
    }

    func listRecentFolders(accessToken: String) async throws -> [GoogleDriveFolderItem] {
        let payload = try await listFiles(
            accessToken: accessToken,
            query: "mimeType = 'application/vnd.google-apps.folder' and trashed = false",
            fields: "files(id,name,driveId,parents,mimeType)",
            corpora: "allDrives",
            driveId: nil,
            includeItemsFromAllDrives: true,
            orderBy: "recency desc, name_natural"
        )
        return try await enrichFolders(payload.files, accessToken: accessToken)
    }

    func listSharedDrives(accessToken: String) async throws -> [GoogleDriveFolderItem] {
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/drives")!
        components.queryItems = [
            .init(name: "pageSize", value: "50"),
            .init(name: "fields", value: "drives(id,name)"),
            .init(name: "q", value: "hidden = false"),
        ]
        let data = try await request(accessToken: accessToken, url: components.url!)
        let payload = try JSONDecoder().decode(DriveListResponse.self, from: data)
        return payload.drives.map {
            GoogleDriveFolderItem(
                id: $0.id,
                name: $0.name,
                detail: L10n.googleDriveSharedDriveLabel,
                kind: .sharedDrive,
                driveId: $0.id,
                driveName: $0.name
            )
        }
        .sorted {
            let nameOrder = $0.name.localizedStandardCompare($1.name)
            if nameOrder != .orderedSame {
                return nameOrder == .orderedAscending
            }
            return $0.id < $1.id
        }
    }

    func fetchFolder(accessToken: String, id: String) async throws -> GoogleDriveFolderItem {
        let file = try await getFile(
            accessToken: accessToken,
            id: id,
            fields: "id,name,driveId,parents,mimeType,trashed"
        )
        guard file.mimeType == "application/vnd.google-apps.folder", file.trashed != true else {
            throw GoogleDriveAPIError.folderNotFound
        }
        guard let folder = try await enrichFolders([file], accessToken: accessToken).first else {
            throw GoogleDriveAPIError.folderNotFound
        }
        return folder
    }

    func upsertGoogleDocument(
        accessToken: String,
        parentFolderId: String,
        fileName: String,
        content: String,
        appProperties: [String: String]
    ) async throws -> String {
        let existingFile = try await findExistingFile(
            accessToken: accessToken,
            parentFolderId: parentFolderId,
            appProperties: appProperties,
            mimeType: Self.googleDocumentMimeType
        )
        let documentName = Self.googleDocumentName(for: fileName)
        let metadata = FileUpdateRequest(
            name: documentName,
            mimeType: Self.googleDocumentMimeType,
            parents: existingFile == nil ? [parentFolderId] : nil,
            appProperties: appProperties
        )
        let importPayload = Self.googleDocumentImportPayload(from: content)

        if let existingFile {
            let updatedFile: DriveFilePayload = try await uploadMultipart(
                accessToken: accessToken,
                method: "PATCH",
                url: Self.uploadURL(forUpdating: existingFile.id),
                metadata: metadata,
                data: importPayload.data,
                dataMimeType: importPayload.mimeType
            )
            return updatedFile.id
        } else {
            let createdFile: DriveFilePayload = try await uploadMultipart(
                accessToken: accessToken,
                method: "POST",
                url: Self.uploadURLForCreate,
                metadata: metadata,
                data: importPayload.data,
                dataMimeType: importPayload.mimeType
            )
            return createdFile.id
        }
    }

    private func enrichFolders(_ files: [DriveFilePayload], accessToken: String) async throws -> [GoogleDriveFolderItem] {
        async let parentNames = batchFetchNames(
            ids: Set(files.compactMap { $0.parents?.first }),
            accessToken: accessToken
        ) { id in
            await (try? self.getFile(accessToken: accessToken, id: id, fields: "id,name"))?.name
        }
        async let driveNames = batchFetchNames(
            ids: Set(files.compactMap(\.driveId)),
            accessToken: accessToken
        ) { id in
            await (try? self.getDrive(accessToken: accessToken, id: id, fields: "id,name"))?.name
        }
        let (resolvedParentNames, resolvedDriveNames) = try await (parentNames, driveNames)

        return files.map { file in
            let parentId = file.parents?.first
            let parentName = parentId.flatMap { resolvedParentNames[$0] }
            let driveName = file.driveId.flatMap { resolvedDriveNames[$0] }
            let detail: String = if let driveName {
                if let parentName, !parentName.isEmpty {
                    "\(driveName) / \(parentName)"
                } else {
                    driveName
                }
            } else if let parentName {
                parentName
            } else {
                file.id
            }
            return GoogleDriveFolderItem(
                id: file.id,
                name: file.name,
                detail: detail,
                driveId: file.driveId,
                driveName: driveName
            )
        }
        .sorted {
            let nameOrder = $0.name.localizedStandardCompare($1.name)
            if nameOrder != .orderedSame {
                return nameOrder == .orderedAscending
            }
            return $0.id < $1.id
        }
    }

    private func batchFetchNames(
        ids: Set<String>,
        accessToken _: String,
        fetchName: @Sendable @escaping (String) async -> String?
    ) async throws -> [String: String] {
        guard !ids.isEmpty else { return [:] }
        return try await withThrowingTaskGroup(of: (String, String?).self) { group in
            for id in ids {
                group.addTask {
                    await (id, fetchName(id))
                }
            }
            var result: [String: String] = [:]
            for try await (id, name) in group {
                if let name {
                    result[id] = name
                }
            }
            return result
        }
    }

    private func findExistingFile(
        accessToken: String,
        parentFolderId: String,
        appProperties: [String: String],
        mimeType: String? = nil
    ) async throws -> DriveFilePayload? {
        let escapedParentID = Self.escapeQueryLiteral(parentFolderId)
        let propertyQuery = appProperties.keys.sorted().compactMap { key -> String? in
            guard let value = appProperties[key] else { return nil }
            let escapedKey = Self.escapeQueryLiteral(key)
            let escapedValue = Self.escapeQueryLiteral(value)
            return "appProperties has { key='\(escapedKey)' and value='\(escapedValue)' }"
        }
        var predicates = [
            "'\(escapedParentID)' in parents",
            "trashed = false",
        ]
        if let mimeType, !mimeType.isEmpty {
            let escapedMimeType = Self.escapeQueryLiteral(mimeType)
            predicates.append("mimeType = '\(escapedMimeType)'")
        }
        predicates.append(contentsOf: propertyQuery)
        let payload = try await listFiles(
            accessToken: accessToken,
            query: predicates.joined(separator: " and "),
            fields: "files(id,name,mimeType)"
        )
        return payload.files.first
    }

    private func listFiles(accessToken: String, query: String, fields: String) async throws -> DriveFilesListResponse {
        try await listFiles(
            accessToken: accessToken,
            query: query,
            fields: fields,
            corpora: "allDrives",
            driveId: nil,
            includeItemsFromAllDrives: true,
            orderBy: nil
        )
    }

    private func listFiles(
        accessToken: String,
        query: String,
        fields: String,
        corpora: String,
        driveId: String?,
        includeItemsFromAllDrives: Bool,
        orderBy: String? = nil
    ) async throws -> DriveFilesListResponse {
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        var queryItems: [URLQueryItem] = [
            .init(name: "q", value: query),
            .init(name: "spaces", value: "drive"),
            .init(name: "corpora", value: corpora),
            .init(name: "includeItemsFromAllDrives", value: includeItemsFromAllDrives ? "true" : "false"),
            .init(name: "supportsAllDrives", value: "true"),
            .init(name: "pageSize", value: "50"),
            .init(name: "fields", value: fields),
        ]
        if let driveId, !driveId.isEmpty {
            queryItems.append(.init(name: "driveId", value: driveId))
        }
        if let orderBy, !orderBy.isEmpty {
            queryItems.append(.init(name: "orderBy", value: orderBy))
        }
        components.queryItems = queryItems
        let data = try await request(accessToken: accessToken, url: components.url!)
        return try JSONDecoder().decode(DriveFilesListResponse.self, from: data)
    }

    private func getFile(accessToken: String, id: String, fields: String) async throws -> DriveFilePayload {
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files/\(id)")!
        components.queryItems = [
            .init(name: "supportsAllDrives", value: "true"),
            .init(name: "fields", value: fields),
        ]
        let data = try await request(accessToken: accessToken, url: components.url!)
        return try JSONDecoder().decode(DriveFilePayload.self, from: data)
    }

    private func getDrive(accessToken: String, id: String, fields: String) async throws -> DrivePayload {
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/drives/\(id)")!
        components.queryItems = [
            .init(name: "fields", value: fields),
        ]
        let data = try await request(accessToken: accessToken, url: components.url!)
        return try JSONDecoder().decode(DrivePayload.self, from: data)
    }

    private func request(accessToken: String, url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GoogleDriveAPIError.invalidResponse
        }

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            let detail = Self.responseDetail(from: data) ?? L10n.googleDriveUnexpectedResponse
            if httpResponse.statusCode == 404 {
                throw GoogleDriveAPIError.folderNotFound
            }
            throw GoogleDriveAPIError.httpError(statusCode: httpResponse.statusCode, detail: detail)
        }

        return data
    }

    private func uploadMultipart<T: Decodable>(
        accessToken: String,
        method: String,
        url: URL,
        metadata: FileUpdateRequest,
        data: Data,
        dataMimeType: String
    ) async throws -> T {
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.multipartBody(
            boundary: boundary,
            metadata: metadata,
            data: data,
            dataMimeType: dataMimeType
        )

        let (responseData, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GoogleDriveAPIError.invalidResponse
        }

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            let detail = Self.responseDetail(from: responseData) ?? L10n.googleDriveUnexpectedResponse
            throw GoogleDriveAPIError.httpError(statusCode: httpResponse.statusCode, detail: detail)
        }

        return try JSONDecoder().decode(T.self, from: responseData)
    }

    private static func multipartBody(
        boundary: String,
        metadata: FileUpdateRequest,
        data: Data,
        dataMimeType: String
    ) throws -> Data {
        let metadataData = try JSONEncoder().encode(metadata)
        var body = Data()
        let lineBreak = "\r\n"

        body.append(Data("--\(boundary)\(lineBreak)".utf8))
        body.append(Data("Content-Type: application/json; charset=UTF-8\(lineBreak)\(lineBreak)".utf8))
        body.append(metadataData)
        body.append(Data("\(lineBreak)--\(boundary)\(lineBreak)".utf8))
        body.append(Data("Content-Type: \(dataMimeType)\(lineBreak)\(lineBreak)".utf8))
        body.append(data)
        body.append(Data("\(lineBreak)--\(boundary)--\(lineBreak)".utf8))
        return body
    }

    private static func responseDetail(from data: Data) -> String? {
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data, encoding: .utf8)
        }

        if let error = payload["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        return String(data: data, encoding: .utf8)
    }

    private static func escapeQueryLiteral(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "\\'")
    }

    private static let uploadURLForCreate =
        URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&supportsAllDrives=true")!
    private static let googleDocumentMimeType = "application/vnd.google-apps.document"

    private static func uploadURL(forUpdating id: String) -> URL {
        URL(string: "https://www.googleapis.com/upload/drive/v3/files/\(id)?uploadType=multipart&supportsAllDrives=true")!
    }

    private static func googleDocumentName(for fileName: String) -> String {
        let trimmed = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Summary" }
        let url = URL(fileURLWithPath: trimmed)
        if url.pathExtension.caseInsensitiveCompare("md") == .orderedSame {
            return url.deletingPathExtension().lastPathComponent
        }
        return url.lastPathComponent
    }

    private static func googleDocumentImportPayload(from content: String) -> DriveImportPayload {
        let body = sanitizeGoogleDocumentMarkdown(googleDocumentBody(from: content))
        return DriveImportPayload(data: Data(body.utf8), mimeType: "text/markdown")
    }

    private static func googleDocumentBody(from content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("---\n") else { return trimmed }

        let lines = trimmed.components(separatedBy: .newlines)
        guard lines.first == "---",
              let closingIndex = lines.dropFirst().firstIndex(of: "---") else {
            return trimmed
        }

        let bodyLines = lines.suffix(from: lines.index(after: closingIndex))
        return bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func sanitizeGoogleDocumentMarkdown(_ markdown: String) -> String {
        var sanitized = markdown.replacingOccurrences(
            of: #"\!\[\[[^\]]+\]\]"#,
            with: "",
            options: .regularExpression
        )

        let matches = obsidianLinkRegex.matches(in: sanitized, range: NSRange(sanitized.startIndex..., in: sanitized))
        for match in matches.reversed() {
            guard let fullRange = Range(match.range(at: 0), in: sanitized) else { continue }
            let replacement = if let aliasRange = Range(match.range(at: 2), in: sanitized) {
                String(sanitized[aliasRange])
            } else {
                ""
            }
            sanitized.replaceSubrange(fullRange, with: replacement)
        }

        sanitized = sanitized.replacingOccurrences(of: #"\(\s*\)"#, with: "", options: .regularExpression)
        sanitized = sanitized.replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
        sanitized = sanitized.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        sanitized = sanitized.replacingOccurrences(of: #"(?m)^[ \t]*[-*+]\s*$\n?"#, with: "", options: .regularExpression)
        sanitized = sanitized.replacingOccurrences(of: #"(?m)^[ \t]*[-*+]\s+\[[ xX]\]\s*$\n?"#, with: "", options: .regularExpression)

        return sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let obsidianLinkRegex = try! NSRegularExpression(
        pattern: #"\[\[([^\]|]+)(?:\|([^\]]+))?\]\]"#
    )
}

private struct DriveFilesListResponse: Decodable {
    let files: [DriveFilePayload]
}

private struct DriveListResponse: Decodable {
    let drives: [DrivePayload]
}

private struct DriveFilePayload: Decodable {
    let id: String
    let name: String
    let driveId: String?
    let parents: [String]?
    let mimeType: String?
    let trashed: Bool?
}

private struct DrivePayload: Decodable {
    let id: String
    let name: String
}

private struct FileUpdateRequest: Encodable {
    let name: String
    let mimeType: String
    let parents: [String]?
    let appProperties: [String: String]
}

private struct DriveImportPayload {
    let data: Data
    let mimeType: String
}
