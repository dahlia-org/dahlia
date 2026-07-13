import Foundation
import GRDB

/// ミーティング要約を表す GRDB レコード。
struct SummaryRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "summaries"

    var meetingId: UUID
    var title: String
    var summary: String
    var document: String? = nil
    var vaultRelativePath: String?
    var googleFileId: String?
    var createdAt: Date

    static func fetchAll(vaultId: UUID, in db: Database) throws -> [Self] {
        try fetchAll(
            db,
            sql: """
            SELECT summaries.*
            FROM summaries
            JOIN meetings ON meetings.id = summaries.meetingId
            WHERE meetings.vaultId = ?
            """,
            arguments: [vaultId]
        )
    }

    static func renameVaultRelativePathsByPrefix(
        oldPrefix: String,
        newPrefix: String,
        vaultId: UUID,
        in db: Database
    ) throws {
        let summaries = try fetchAll(vaultId: vaultId, in: db)

        for var summary in summaries {
            guard let relativePath = summary.vaultRelativePath,
                  relativePath == oldPrefix || relativePath.hasPrefix(oldPrefix + "/")
            else { continue }
            summary.vaultRelativePath = newPrefix + relativePath.dropFirst(oldPrefix.count)
            try summary.update(db)
        }
    }

    static func renameVaultRelativePath(
        from oldPath: String,
        to newPath: String,
        vaultId: UUID,
        in db: Database
    ) throws {
        try db.execute(
            sql: """
            UPDATE summaries
            SET vaultRelativePath = ?
            WHERE vaultRelativePath = ?
              AND meetingId IN (SELECT id FROM meetings WHERE vaultId = ?)
            """,
            arguments: [newPath, oldPath, vaultId]
        )
    }

    static func clearVaultRelativePath(_ relativePath: String, vaultId: UUID, in db: Database) throws {
        try db.execute(
            sql: """
            UPDATE summaries
            SET vaultRelativePath = NULL
            WHERE vaultRelativePath = ?
              AND meetingId IN (SELECT id FROM meetings WHERE vaultId = ?)
            """,
            arguments: [relativePath, vaultId]
        )
    }

    static func clearVaultRelativePaths(
        meetingIds: Set<UUID>,
        underProjectPrefix projectPrefix: String,
        in db: Database
    ) throws {
        guard !meetingIds.isEmpty else { return }
        let summaries = try SummaryRecord
            .filter(meetingIds.contains(Column("meetingId")))
            .fetchAll(db)
        for var summary in summaries {
            guard let path = summary.vaultRelativePath,
                  ProjectRecord.belongsToHierarchy(path, prefix: projectPrefix)
            else { continue }
            summary.vaultRelativePath = nil
            try summary.update(db)
        }
    }

    func loadDocument() -> SummaryDocument {
        if let document = document?.nilIfBlank,
           let data = document.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(SummaryDocument.self, from: data) {
            return decoded
        }

        return LegacyMarkdownSummaryParser.parse(markdown: summary, title: title)
    }
}
