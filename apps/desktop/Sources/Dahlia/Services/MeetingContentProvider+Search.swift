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
