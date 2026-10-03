import Foundation

protocol GoogleDriveAPIClientProviding: AnyObject, Sendable {
    func isExportFolderAvailable(
        accessToken: String,
        folderID: String
    ) async throws -> Bool

    func resolveExportFolderID(
        accessToken: String,
        folderName: String
    ) async throws -> String

    func upsertGoogleDocument(
        accessToken: String,
        fileName: String,
        data: Data,
        dataMimeType: String,
        appProperties: [String: String],
        parentFolderID: String
    ) async throws -> String
}

enum GoogleDriveAPIError: LocalizedError, Equatable {
    case invalidResponse
    case exportFolderNotConfigured
    case httpError(statusCode: Int, detail: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            L10n.googleDriveUnexpectedResponse
        case .exportFolderNotConfigured:
            L10n.googleDriveExportFolderNotConfigured
        case let .httpError(statusCode, detail):
            L10n.googleDriveHTTPError(statusCode, detail)
        }
    }
}

final class GoogleDriveAPIClient: GoogleDriveAPIClientProviding, @unchecked Sendable {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func isExportFolderAvailable(
        accessToken: String,
        folderID: String
    ) async throws -> Bool {
        guard var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files/\(folderID)") else {
            throw GoogleDriveAPIError.invalidResponse
        }
        components.queryItems = [
            .init(name: "supportsAllDrives", value: "true"),
            .init(name: "fields", value: "mimeType,trashed"),
        ]
        guard let url = components.url else {
            throw GoogleDriveAPIError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GoogleDriveAPIError.invalidResponse
        }
        if [403, 404].contains(httpResponse.statusCode) {
            return false
        }
        try Self.validate(response: response, data: data)
        let folder = try JSONDecoder().decode(DriveFolderValidationPayload.self, from: data)
        return folder.mimeType == Self.googleFolderMimeType && !folder.trashed
    }

    func resolveExportFolderID(
        accessToken: String,
        folderName: String
    ) async throws -> String {
        if let existingFolderID = try await findExportFolderID(
            accessToken: accessToken,
            folderName: folderName
        ) {
            return existingFolderID
        }
        return try await createExportFolder(
            accessToken: accessToken,
            folderName: folderName
        )
    }

    func upsertGoogleDocument(
        accessToken: String,
        fileName: String,
        data: Data,
        dataMimeType: String,
        appProperties: [String: String],
        parentFolderID: String
    ) async throws -> String {
        let existingFile = try await findExistingFile(
            accessToken: accessToken,
            appProperties: appProperties
        )
        let metadata = GoogleDocumentMetadata(
            name: Self.googleDocumentName(for: fileName),
            mimeType: Self.googleDocumentMimeType,
            appProperties: appProperties,
            parents: existingFile == nil ? [parentFolderID] : nil
        )
        return try await uploadResumable(
            accessToken: accessToken,
            existingFile: existingFile,
            parentFolderID: parentFolderID,
            metadata: metadata,
            data: data,
            dataMimeType: dataMimeType
        )
    }

    private func findExportFolderID(
        accessToken: String,
        folderName: String
    ) async throws -> String? {
        let predicates = [
            "mimeType = '\(Self.googleFolderMimeType)'",
            "name = '\(Self.escapeQueryLiteral(folderName))'",
            "'root' in parents",
            "trashed = false",
            "appProperties has { key='dahliaKind' and value='exportFolder' }",
        ]
        let files = try await listFiles(
            accessToken: accessToken,
            predicates: predicates,
            corpora: "user",
            pageSize: 1
        )
        return files.first?.id
    }

    private func createExportFolder(
        accessToken: String,
        folderName: String
    ) async throws -> String {
        guard var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files") else {
            throw GoogleDriveAPIError.invalidResponse
        }
        components.queryItems = [
            .init(name: "supportsAllDrives", value: "true"),
            .init(name: "fields", value: "id"),
        ]
        guard let url = components.url else {
            throw GoogleDriveAPIError.invalidResponse
        }

        let metadata = DriveFolderMetadata(
            name: folderName,
            mimeType: Self.googleFolderMimeType,
            parents: ["root"],
            appProperties: ["dahliaKind": "exportFolder"]
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(metadata)

        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response, data: data)
        return try JSONDecoder().decode(DriveFilePayload.self, from: data).id
    }

    private func findExistingFile(
        accessToken: String,
        appProperties: [String: String]
    ) async throws -> DriveFilePayload? {
        let propertyPredicates = appProperties.sorted { $0.key < $1.key }.map { key, value in
            "appProperties has { key='\(Self.escapeQueryLiteral(key))' and value='\(Self.escapeQueryLiteral(value))' }"
        }
        var predicates = [
            "mimeType = '\(Self.googleDocumentMimeType)'",
            "trashed = false",
        ]
        predicates.append(contentsOf: propertyPredicates)

        return try await listFiles(
            accessToken: accessToken,
            predicates: predicates,
            corpora: "allDrives",
            pageSize: 10
        ).first
    }

    private func listFiles(
        accessToken: String,
        predicates: [String],
        corpora: String,
        pageSize: Int
    ) async throws -> [DriveFilePayload] {
        guard var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files") else {
            throw GoogleDriveAPIError.invalidResponse
        }
        components.queryItems = [
            .init(name: "q", value: predicates.joined(separator: " and ")),
            .init(name: "spaces", value: "drive"),
            .init(name: "corpora", value: corpora),
            .init(name: "includeItemsFromAllDrives", value: "true"),
            .init(name: "supportsAllDrives", value: "true"),
            .init(name: "pageSize", value: String(pageSize)),
            .init(name: "fields", value: "files(id,parents)"),
        ]
        guard let url = components.url else {
            throw GoogleDriveAPIError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response, data: data)
        return try JSONDecoder().decode(DriveFilesListResponse.self, from: data).files
    }

    private func uploadResumable(
        accessToken: String,
        existingFile: DriveFilePayload?,
        parentFolderID: String,
        metadata: GoogleDocumentMetadata,
        data: Data,
        dataMimeType: String
    ) async throws -> String {
        let initialURL = try Self.resumableUploadURL(
            existingFile: existingFile,
            parentFolderID: parentFolderID
        )
        var initialRequest = URLRequest(url: initialURL)
        initialRequest.httpMethod = existingFile == nil ? "POST" : "PATCH"
        initialRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        initialRequest.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        initialRequest.setValue(dataMimeType, forHTTPHeaderField: "X-Upload-Content-Type")
        initialRequest.setValue(String(data.count), forHTTPHeaderField: "X-Upload-Content-Length")
        initialRequest.httpBody = try JSONEncoder().encode(metadata)

        let (initialData, initialResponse) = try await session.data(for: initialRequest)
        try Self.validate(response: initialResponse, data: initialData)
        guard let httpResponse = initialResponse as? HTTPURLResponse,
              let location = httpResponse.value(forHTTPHeaderField: "Location"),
              let uploadURL = URL(string: location) else {
            throw GoogleDriveAPIError.invalidResponse
        }

        var uploadRequest = URLRequest(url: uploadURL)
        uploadRequest.httpMethod = "PUT"
        uploadRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        uploadRequest.setValue(dataMimeType, forHTTPHeaderField: "Content-Type")
        uploadRequest.setValue(String(data.count), forHTTPHeaderField: "Content-Length")
        uploadRequest.httpBody = data

        let (responseData, response) = try await session.data(for: uploadRequest)
        try Self.validate(response: response, data: responseData)
        return try JSONDecoder().decode(DriveFilePayload.self, from: responseData).id
    }

    private static func resumableUploadURL(
        existingFile: DriveFilePayload?,
        parentFolderID: String
    ) throws -> URL {
        let endpoint = if let existingFile {
            "https://www.googleapis.com/upload/drive/v3/files/\(existingFile.id)"
        } else {
            "https://www.googleapis.com/upload/drive/v3/files"
        }
        guard var components = URLComponents(string: endpoint) else {
            throw GoogleDriveAPIError.invalidResponse
        }
        components.queryItems = [
            .init(name: "uploadType", value: "resumable"),
            .init(name: "supportsAllDrives", value: "true"),
            .init(name: "fields", value: "id"),
        ]
        if let existingFile, existingFile.parents?.contains(parentFolderID) != true {
            components.queryItems?.append(.init(name: "addParents", value: parentFolderID))
            if let parents = existingFile.parents, !parents.isEmpty {
                components.queryItems?.append(.init(name: "removeParents", value: parents.joined(separator: ",")))
            }
        }
        guard let url = components.url else {
            throw GoogleDriveAPIError.invalidResponse
        }
        return url
    }

    private static func validate(response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GoogleDriveAPIError.invalidResponse
        }
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            let detail = responseDetail(from: data) ?? L10n.googleDriveUnexpectedResponse
            throw GoogleDriveAPIError.httpError(statusCode: httpResponse.statusCode, detail: detail)
        }
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
        value
            .replacing("\\", with: "\\\\")
            .replacing("'", with: "\\'")
    }

    private static func googleDocumentName(for fileName: String) -> String {
        let trimmed = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Summary" }

        for pathExtension in [".md", ".rtf"] where trimmed.lowercased().hasSuffix(pathExtension) {
            return String(trimmed.dropLast(pathExtension.count))
        }
        return trimmed
    }

    private static let googleDocumentMimeType = "application/vnd.google-apps.document"
    private static let googleFolderMimeType = "application/vnd.google-apps.folder"
}

private struct DriveFilesListResponse: Decodable {
    let files: [DriveFilePayload]
}

private struct DriveFilePayload: Decodable {
    let id: String
    let parents: [String]?
}

private struct GoogleDocumentMetadata: Encodable {
    let name: String
    let mimeType: String
    let appProperties: [String: String]
    let parents: [String]?
}

private struct DriveFolderMetadata: Encodable {
    let name: String
    let mimeType: String
    let parents: [String]
    let appProperties: [String: String]
}

private struct DriveFolderValidationPayload: Decodable {
    let mimeType: String
    let trashed: Bool
}
