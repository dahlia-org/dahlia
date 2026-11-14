import DahliaRuntimeSupport
import DahliaServerAPI
import Foundation
import GRDB

struct SummaryHistoryService: Sendable {
    var client = SyncAPIClient(session: .shared)

    struct Page: Decodable, Sendable {
        let items: [SummaryVersion]
        let nextCursor: String?
    }

    func page(meetingID: UUID, dbQueue: DatabaseQueue, before: String? = nil) async throws -> Page {
        if let target = try await ServerSummaryService.shared.target(meetingID: meetingID, dbQueue: dbQueue) {
            guard let origin = URL(string: target.origin) else { throw URLError(.badURL) }
            let data = try await client.data(origin: origin, connectionId: target.connectionID, maximumBytes: 4 * 1024 * 1024) {
                try await $0.listSummaries(path: .init(meetingId: meetingID.uuidString.lowercased()), query: .init(cursor: before, limit: "20")).ok
                    .body.json
            }
            return try SyncJSON.decoder.decode(Page.self, from: data)
        }
        return try await dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
            SELECT version, title, savedAt,
                CASE WHEN json_valid(document) THEN json_extract(document, '$.metadata') END AS metadata
            FROM summary_versions WHERE meetingId = ? AND version < ? ORDER BY version DESC LIMIT 21
            """, arguments: [meetingID, before.flatMap(Int.init) ?? Int.max])
            let items = try rows.prefix(20).map { row in
                let metadata: String? = row["metadata"]
                return try SummaryVersion(
                    version: row["version"], title: row["title"], savedAt: row["savedAt"],
                    metadata: metadata.map { try JSONDecoder().decode(SummaryMetadata.self, from: Data($0.utf8)) }
                )
            }
            return Page(items: items, nextCursor: rows.count > 20 ? items.last.map { String($0.version) } : nil)
        }
    }

    func document(meetingID: UUID, version: Int, dbQueue: DatabaseQueue) async throws -> SummaryDocument {
        let json: String
        if let target = try await ServerSummaryService.shared.target(meetingID: meetingID, dbQueue: dbQueue) {
            guard let origin = URL(string: target.origin) else { throw URLError(.badURL) }
            let data = try await client.data(origin: origin, connectionId: target.connectionID, maximumBytes: 4 * 1024 * 1024) {
                try await $0.getSummary(path: .init(meetingId: meetingID.uuidString.lowercased(), version: String(version))).ok.body.json
            }
            let record = try SyncJSON.decoder.decode(SummaryVersion.self, from: data)
            guard let document = record.document else { throw URLError(.cannotDecodeContentData) }
            json = document
        } else {
            json = try await dbQueue.read { db in
                guard let record = try SummaryVersionRecord.fetchOne(
                    db,
                    key: ["meetingId": meetingID.databaseValue, "version": version.databaseValue]
                )
                else { throw URLError(.fileDoesNotExist) }
                return record.document
            }
        }
        return try await Task.detached(priority: .userInitiated) { try SummaryDocument.decode(databaseJSON: json) }.value
    }

    func promote(meetingID: UUID, document: SummaryDocument, dbQueue: DatabaseQueue) async throws -> SummaryDocument {
        try Task.checkCancellation()
        try await Task.detached(priority: .userInitiated) {
            try MeetingRepository(dbQueue: dbQueue).promoteSummary(meetingID: meetingID, document: document)
        }.value
        return document
    }
}
