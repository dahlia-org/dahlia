import DahliaRuntimeSupport
import Foundation
import GRDB

extension MeetingContentProvider {
    struct SearchSource: Equatable, Sendable {
        let connectionId: UUID
        let origin: String
        let generation: Int64

        static func read(vaultId: UUID, in db: Database) throws -> Self? {
            guard let row = try Row.fetchOne(db, sql: """
            SELECT v.accountConnectionId, c.origin, v.syncMutationGeneration
            FROM vaults v JOIN dahlia_account_connections c ON c.id = v.accountConnectionId
            WHERE v.id = ? AND v.syncConfirmedConnectionId = v.accountConnectionId
            """, arguments: [vaultId]) else { return nil }
            return Self(connectionId: row["accountConnectionId"], origin: row["origin"], generation: row["syncMutationGeneration"])
        }
    }

    func search(
        vaultId: UUID,
        query: String,
        kind: TextSearchKind,
        cursor: String? = nil,
        limit: Int = 200,
        dbQueue: DatabaseQueue
    ) async throws -> TextSearchPage {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // Server's JavaScript String.length counts UTF-16 code units.
        guard !query.isEmpty, query.utf16.count <= 500, (1 ... 200).contains(limit) else { throw TextContentError.unavailable }
        guard let source = try await dbQueue.read({ try SearchSource.read(vaultId: vaultId, in: $0) }),
              var url = URLComponents(string: source.origin) else { throw TextContentError.unavailable }
        url.path = "/api/v1/vaults/\(vaultId.uuidString.lowercased())/search"
        url.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "kind", value: kind.rawValue),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        if let cursor { url.queryItems?.append(URLQueryItem(name: "cursor", value: cursor)) }
        guard let address = url.url else { throw URLError(.badURL) }
        let bytes = try await client.data(for: URLRequest(url: address), connectionId: source.connectionId, maximumBytes: 1024 * 1024)
        try Task.checkCancellation()
        guard try await dbQueue.read({ try SearchSource.read(vaultId: vaultId, in: $0) }) == source else { throw TextContentError.changed }
        let page = try SyncJSON.decoder.decode(TextSearchPage.self, from: bytes)
        guard page.version == 1, page.scope == "server", page.items.count <= 200,
              page.nextCursor == nil || page.nextCursor != cursor else { throw TextContentError.integrityFailure }
        return page
    }
}

extension MeetingContentProvider {
    func searchAll(vaultId: UUID, criteria: MeetingSearchCriteria, dbQueue: DatabaseQueue) async throws -> ServerSearchResults {
        guard criteria.tagIDs.isEmpty, criteria.projectIDs.count <= 1, criteria.text.utf16.count <= 500,
              let source = try await dbQueue.read({ try SearchSource.read(vaultId: vaultId, in: $0) }),
              let origin = URL(string: source.origin),
              let capabilitiesURL = URL(string: "/api/v1/capabilities", relativeTo: origin)?.absoluteURL,
              let searchURL = URL(string: "/api/v1/search", relativeTo: origin)?.absoluteURL else { throw TextContentError.unavailable }
        let capabilities = try await client.data(
            for: URLRequest(url: capabilitiesURL, cachePolicy: .reloadIgnoringLocalCacheData),
            connectionId: source.connectionId, maximumBytes: 8192
        )
        guard try JSONDecoder().decode(ServerCapabilities.self, from: capabilities).search?.version == 1 else { throw TextContentError.unavailable }
        struct Body: Encodable {
            let vaultId: UUID
            let query: String
            let projectId: UUID?
            let from: Date?
            let to: Date?
            let limit = 100
        }
        var request = URLRequest(url: searchURL, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try SyncJSON.encoder.encode(Body(
            vaultId: vaultId, query: criteria.text, projectId: criteria.projectIDs.first,
            from: criteria.startDate, to: criteria.endDate
        ))
        let bytes = try await client.data(for: request, connectionId: source.connectionId, maximumBytes: 1024 * 1024)
        try Task.checkCancellation()
        guard try await dbQueue.read({ try SearchSource.read(vaultId: vaultId, in: $0) }) == source else { throw TextContentError.changed }
        let result = try SyncJSON.decoder.decode(ServerSearchResults.self, from: bytes)
        guard result.vaultId == vaultId,
              result.meetings.count <= 100, result.screenshots.count <= 100, result.projects.count <= 100,
              result.meetings.allSatisfy({ $0.kind == "meeting" && $0.meetingId == $0.id }),
              result.screenshots.allSatisfy({ $0.kind == "screenshot" && $0.meetingId != nil && $0.fileId != nil }),
              result.projects.allSatisfy({ $0.kind == "project" && $0.projectId == $0.id }),
              Set(result.meetings.map(\.id)).count == result.meetings.count,
              Set(result.screenshots.map(\.id)).count == result.screenshots.count,
              Set(result.projects.map(\.id)).count == result.projects.count else { throw TextContentError.integrityFailure }
        return result
    }
}
