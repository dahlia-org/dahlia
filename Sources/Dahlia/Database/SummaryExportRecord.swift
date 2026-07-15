import Foundation
import GRDB

struct SummaryExportRecord: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "summary_exports"

    var meetingId: UUID
    var type: SummaryExportType
    /// `vault` は Vault 相対 URL、`google_docs` は完全な URL。
    var url: String
    var createdAt: Date
    var updatedAt: Date

    var googleDocumentID: String? {
        guard type == .googleDocs,
              let url = URL(string: url)
        else { return nil }
        let components = url.pathComponents
        guard let documentMarkerIndex = components.firstIndex(of: "d"),
              components.indices.contains(components.index(after: documentMarkerIndex))
        else { return nil }
        return components[components.index(after: documentMarkerIndex)].nilIfBlank
    }

    var vaultRelativePath: String? {
        guard type == .vault,
              let components = URLComponents(string: url),
              components.scheme?.lowercased() == SummaryExportType.vault.rawValue,
              components.host?.nilIfBlank == nil
        else { return nil }
        return String(components.path.drop(while: { $0 == "/" })).nilIfBlank
    }

    static func vaultURL(relativePath: String) -> String? {
        guard let relativePath = relativePath.nilIfBlank else { return nil }
        let normalizedPath = String(relativePath.drop(while: { $0 == "/" }))
        guard !normalizedPath.isEmpty else { return nil }

        var components = URLComponents()
        components.scheme = SummaryExportType.vault.rawValue
        components.host = ""
        components.path = "/" + normalizedPath
        return components.string
    }

    static func googleDocsURL(fileId: String) -> String? {
        URL(string: "https://docs.google.com/document/d")?
            .appending(path: fileId)
            .appending(path: "edit")
            .absoluteString
    }

    static func fetchOne(
        meetingId: UUID,
        type: SummaryExportType,
        in db: Database
    ) throws -> Self? {
        try filter(Column("meetingId") == meetingId)
            .filter(Column("type") == type)
            .fetchOne(db)
    }

    static func setURL(
        _ url: String?,
        meetingId: UUID,
        type: SummaryExportType,
        updatedAt: Date = .now,
        in db: Database
    ) throws {
        guard let url = url?.nilIfBlank else {
            _ = try filter(Column("meetingId") == meetingId)
                .filter(Column("type") == type)
                .deleteAll(db)
            return
        }
        let existing = try fetchOne(meetingId: meetingId, type: type, in: db)
        try Self(
            meetingId: meetingId,
            type: type,
            url: url,
            createdAt: existing?.createdAt ?? updatedAt,
            updatedAt: updatedAt
        ).save(db)
    }

    static func renameVaultPathsByPrefix(
        oldPrefix: String,
        newPrefix: String,
        vaultId: UUID,
        in db: Database
    ) throws {
        let records = try fetchAll(
            db,
            sql: """
            SELECT summary_exports.*
            FROM summary_exports
            JOIN meetings ON meetings.id = summary_exports.meetingId
            WHERE summary_exports.type = ? AND meetings.vaultId = ?
            """,
            arguments: [SummaryExportType.vault, vaultId]
        )

        for var record in records {
            guard let relativePath = record.vaultRelativePath,
                  relativePath == oldPrefix || relativePath.hasPrefix(oldPrefix + "/"),
                  let newURL = vaultURL(relativePath: newPrefix + relativePath.dropFirst(oldPrefix.count))
            else { continue }
            record.url = newURL
            record.updatedAt = Date.now
            try record.update(db)
        }
    }

    static func renameVaultPath(
        from oldPath: String,
        to newPath: String,
        vaultId: UUID,
        in db: Database
    ) throws {
        guard let oldURL = vaultURL(relativePath: oldPath),
              let newURL = vaultURL(relativePath: newPath) else { return }
        try db.execute(
            sql: """
            UPDATE summary_exports
            SET url = ?, updatedAt = ?
            WHERE type = ?
              AND url = ?
              AND meetingId IN (SELECT id FROM meetings WHERE vaultId = ?)
            """,
            arguments: [newURL, Date.now, SummaryExportType.vault, oldURL, vaultId]
        )
    }

    static func clearVaultPath(_ relativePath: String, vaultId: UUID, in db: Database) throws {
        guard let url = vaultURL(relativePath: relativePath) else { return }
        try db.execute(
            sql: """
            DELETE FROM summary_exports
            WHERE type = ?
              AND url = ?
              AND meetingId IN (SELECT id FROM meetings WHERE vaultId = ?)
            """,
            arguments: [SummaryExportType.vault, url, vaultId]
        )
    }

    static func clearVaultPaths(
        meetingIds: Set<UUID>,
        underProjectPrefix projectPrefix: String,
        in db: Database
    ) throws {
        guard !meetingIds.isEmpty else { return }
        let records = try filter(meetingIds.contains(Column("meetingId")))
            .filter(Column("type") == SummaryExportType.vault)
            .fetchAll(db)
        for record in records where record.vaultRelativePath.map({
            ProjectRecord.belongsToHierarchy($0, prefix: projectPrefix)
        }) == true {
            _ = try record.delete(db)
        }
    }
}
