import DahliaRuntimeSupport
import Foundation
import GRDB

struct SummaryHistoryService: Sendable {
    struct Page: Decodable, Sendable {
        let items: [SummaryVersion]
        let nextCursor: String?
        /// The version marked as the current summary.
        var currentVersion: Int?
    }

    func page(meetingID: UUID, dbQueue: any DatabaseWriter, before: String? = nil) async throws -> Page {
        try await dbQueue.read { db in
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
            let currentVersion = try Int.fetchOne(
                db, sql: "SELECT version FROM summary_versions WHERE meetingId = ? AND isCurrent", arguments: [meetingID]
            )
            return Page(
                items: items, nextCursor: rows.count > 20 ? items.last.map { String($0.version) } : nil, currentVersion: currentVersion
            )
        }
    }

    func document(meetingID: UUID, version: Int, dbQueue: any DatabaseWriter) async throws -> SummaryDocument {
        let json = try await dbQueue.read { db in
            guard let record = try SummaryVersionRecord.fetchOne(
                db,
                key: ["meetingId": meetingID.databaseValue, "version": version.databaseValue]
            )
            else { throw URLError(.fileDoesNotExist) }
            return record.document
        }
        return try await Task.detached(priority: .userInitiated) { try SummaryDocument.decode(databaseJSON: json) }.value
    }

    func promote(meetingID: UUID, version: Int, dbQueue: any DatabaseWriter) async throws {
        try Task.checkCancellation()
        try await Task.detached(priority: .userInitiated) {
            try MeetingRepository(dbQueue: dbQueue).promoteSummary(meetingID: meetingID, version: version)
        }.value
    }
}
