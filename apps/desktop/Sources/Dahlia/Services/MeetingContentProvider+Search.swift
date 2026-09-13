import DahliaRuntimeSupport
import DahliaServerAPI
import Foundation
import GRDB

extension MeetingContentProvider {
    struct SearchSource: Equatable, Sendable {
        let connectionId: UUID
        let origin: String
        let generation: Int64

        static func read(workspaceId: UUID, in db: Database) throws -> Self? {
            guard let row = try Row.fetchOne(db, sql: """
            SELECT v.accountConnectionId, c.origin, v.syncMutationGeneration
            FROM workspaces v JOIN dahlia_account_connections c ON c.id = v.accountConnectionId
            WHERE v.id = ? AND v.syncConfirmedConnectionId = v.accountConnectionId
            """, arguments: [workspaceId]) else { return nil }
            return Self(connectionId: row["accountConnectionId"], origin: row["origin"], generation: row["syncMutationGeneration"])
        }
    }

    func search(
        workspaceId: UUID,
        query: String,
        kind: TextSearchKind,
        cursor: String? = nil,
        limit: Int = 200,
        dbQueue: DatabaseQueue
    ) async throws -> TextSearchPage {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // Server's JavaScript String.length counts UTF-16 code units.
        guard !query.isEmpty, query.utf16.count <= 500, (1 ... 200).contains(limit) else { throw TextContentError.unavailable }
        guard let source = try await dbQueue.read({ try SearchSource.read(workspaceId: workspaceId, in: $0) }),
              let origin = URL(string: source.origin),
              let searchKind = Components.Schemas.TextSearchRequest.KindPayload(rawValue: kind.rawValue) else { throw TextContentError.unavailable }
        let bytes = try await client.data(origin: origin, connectionId: source.connectionId, maximumBytes: 1024 * 1024) {
            try await $0.textSearch(
                path: .init(workspaceId: workspaceId.uuidString.lowercased()),
                body: .json(.init(query: query, kind: searchKind, cursor: cursor, limit: limit))
            ).ok.body.json
        }
        try Task.checkCancellation()
        guard try await dbQueue.read({ try SearchSource.read(workspaceId: workspaceId, in: $0) }) == source else { throw TextContentError.changed }
        let page = try SyncJSON.decoder.decode(TextSearchPage.self, from: bytes)
        guard page.version == 1, page.scope == "server", page.items.count <= 200,
              page.nextCursor == nil || page.nextCursor != cursor else { throw TextContentError.integrityFailure }
        return page
    }
}

extension MeetingContentProvider {
    func searchAll(workspaceId: UUID, criteria: MeetingSearchCriteria, dbQueue: DatabaseQueue) async throws -> ServerSearchResults {
        guard criteria.tagIDs.isEmpty, criteria.projectIDs.count <= 1, criteria.text.utf16.count <= 500,
              let source = try await dbQueue.read({ try SearchSource.read(workspaceId: workspaceId, in: $0) }),
              let origin = URL(string: source.origin) else { throw TextContentError.unavailable }
        let capabilities = try await client.data(origin: origin, connectionId: source.connectionId, maximumBytes: 8192) {
            try await $0.getCapabilities().ok.body.json
        }
        guard try JSONDecoder().decode(ServerCapabilities.self, from: capabilities).search?.version == 1 else { throw TextContentError.unavailable }
        let body = Operations.Search.Input.Body.JsonPayload(
            query: criteria.text,
            projectId: criteria.projectIDs.first?.uuidString.lowercased(),
            from: criteria.startDate,
            to: criteria.endDate,
            limit: 100
        )
        let bytes = try await client.data(origin: origin, connectionId: source.connectionId, maximumBytes: 1024 * 1024) {
            try await $0.search(path: .init(workspaceId: workspaceId.uuidString.lowercased()), body: .json(body)).ok.body.json
        }
        try Task.checkCancellation()
        guard try await dbQueue.read({ try SearchSource.read(workspaceId: workspaceId, in: $0) }) == source else { throw TextContentError.changed }
        let result = try SyncJSON.decoder.decode(ServerSearchResults.self, from: bytes)
        guard result.workspaceId == workspaceId,
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
