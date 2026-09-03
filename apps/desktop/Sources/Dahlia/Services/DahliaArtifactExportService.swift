import Foundation

enum DahliaArtifactExportError: LocalizedError {
    case invalidResponse
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            L10n.dahliaArtifactUnexpectedResponse
        case let .httpError(statusCode):
            L10n.dahliaArtifactHTTPError(statusCode)
        }
    }
}

struct DahliaArtifactExportResult: Sendable {
    let url: URL
    let wasCreated: Bool
}

enum DahliaArtifactExportService {
    static let requiredScope = "api.artifact.write"

    static func export(
        html: String,
        connectionID: UUID,
        origin: String,
        existingURL: URL? = nil,
        urlSession: URLSession = .shared,
        tokenProvider: @Sendable (UUID) async throws -> String = {
            try await DahliaCloudTokenServiceRegistry.shared.validAccessToken(connectionID: $0)
        }
    ) async throws -> DahliaArtifactExportResult {
        guard let baseURL = URL(string: origin) else {
            throw DahliaArtifactExportError.invalidResponse
        }
        let body = Data(html.utf8)
        let accessToken = try await tokenProvider(connectionID)
        let replacementURL = existingURL.flatMap { canonicalArtifactURL($0, origin: origin) }
        var request = URLRequest(url: replacementURL ?? baseURL.appending(path: "api/v1/artifacts"))
        request.httpMethod = replacementURL == nil ? "POST" : "PUT"
        request.httpBody = body
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("text/html", forHTTPHeaderField: "Content-Type")
        request.setValue("attachment; filename=\"summary.html\"", forHTTPHeaderField: "Content-Disposition")
        request.setValue(String(body.count), forHTTPHeaderField: "Content-Length")

        let (data, response) = try await urlSession.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw DahliaArtifactExportError.invalidResponse
        }
        if replacementURL != nil, response.statusCode == 404 {
            return try await export(
                html: html,
                connectionID: connectionID,
                origin: origin,
                urlSession: urlSession,
                tokenProvider: { _ in accessToken }
            )
        }
        let expectedStatus = replacementURL == nil ? 201 : 200
        guard response.statusCode == expectedStatus else {
            throw DahliaArtifactExportError.httpError(response.statusCode)
        }
        let payload = try JSONDecoder().decode(Response.self, from: data)
        let canonicalURL = baseURL
            .appending(path: "api/v1/artifacts")
            .appending(path: payload.id)
        guard payload.visibility == "private",
              payload.contentType == "text/html",
              isUUIDv7(payload.id),
              replacementURL == nil || replacementURL == canonicalURL else {
            throw DahliaArtifactExportError.invalidResponse
        }
        if replacementURL == nil {
            guard response.value(forHTTPHeaderField: "Location") == canonicalURL.absoluteString else {
                throw DahliaArtifactExportError.invalidResponse
            }
        }
        return DahliaArtifactExportResult(url: canonicalURL, wasCreated: replacementURL == nil)
    }

    static func delete(
        url: URL,
        connectionID: UUID,
        origin: String,
        urlSession: URLSession = .shared,
        tokenProvider: @Sendable (UUID) async throws -> String = {
            try await DahliaCloudTokenServiceRegistry.shared.validAccessToken(connectionID: $0)
        }
    ) async throws {
        guard let url = canonicalArtifactURL(url, origin: origin) else {
            throw DahliaArtifactExportError.invalidResponse
        }
        let accessToken = try await tokenProvider(connectionID)
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await urlSession.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw DahliaArtifactExportError.invalidResponse
        }
        guard response.statusCode == 204 else {
            throw DahliaArtifactExportError.httpError(response.statusCode)
        }
    }

    private static func canonicalArtifactURL(_ url: URL, origin: String) -> URL? {
        guard DahliaCloudService.sameOrigin(url.absoluteString, origin),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.query == nil,
              components.fragment == nil else { return nil }
        let pathComponents = url.pathComponents
        guard pathComponents.count == 5,
              pathComponents[1 ... 3] == ["api", "v1", "artifacts"],
              isUUIDv7(pathComponents[4]),
              let baseURL = URL(string: origin) else { return nil }
        let canonicalURL = baseURL
            .appending(path: "api/v1/artifacts")
            .appending(path: pathComponents[4])
        return url.absoluteString == canonicalURL.absoluteString ? canonicalURL : nil
    }

    private static func isUUIDv7(_ value: String) -> Bool {
        guard value == value.lowercased(),
              let uuid = UUID(uuidString: value),
              uuid.uuidString.lowercased() == value else { return false }
        let versionIndex = value.index(value.startIndex, offsetBy: 14)
        let variantIndex = value.index(value.startIndex, offsetBy: 19)
        return value[versionIndex] == "7" && "89ab".contains(value[variantIndex])
    }

    private struct Response: Decodable {
        let id: String
        let visibility: String
        let contentType: String
    }
}
