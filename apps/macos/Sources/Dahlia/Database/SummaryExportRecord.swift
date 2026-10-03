import Foundation
import GRDB

struct SummaryExportRecord: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "summary_exports"

    var meetingId: UUID
    var type: SummaryExportType
    /// `workspace` は Workspace 相対 URL、それ以外は完全な URL。
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

    var workspaceRelativePath: String? {
        guard type == .workspace,
              let components = URLComponents(string: url),
              components.scheme?.lowercased() == SummaryExportType.workspace.rawValue,
              components.host?.nilIfBlank == nil
        else { return nil }
        return String(components.path.drop(while: { $0 == "/" })).nilIfBlank
    }

    static func workspaceURL(relativePath: String) -> String? {
        guard let relativePath = relativePath.nilIfBlank else { return nil }
        let normalizedPath = String(relativePath.drop(while: { $0 == "/" }))
        guard !normalizedPath.isEmpty else { return nil }

        var components = URLComponents()
        components.scheme = SummaryExportType.workspace.rawValue
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

    static func renameWorkspacePathsByPrefix(
        oldPrefix: String,
        newPrefix: String,
        workspaceId: UUID,
        in db: Database
    ) throws {
        let records = try fetchAll(
            db,
            sql: """
            SELECT summary_exports.*
            FROM summary_exports
            JOIN meetings ON meetings.id = summary_exports.meetingId
            WHERE summary_exports.type = ? AND meetings.workspace_id = ?
            """,
            arguments: [SummaryExportType.workspace, workspaceId]
        )

        for var record in records {
            guard let relativePath = record.workspaceRelativePath,
                  relativePath == oldPrefix || relativePath.hasPrefix(oldPrefix + "/"),
                  let newURL = workspaceURL(relativePath: newPrefix + relativePath.dropFirst(oldPrefix.count))
            else { continue }
            record.url = newURL
            record.updatedAt = Date.now
            try record.update(db)
        }
    }

    static func renameWorkspacePath(
        from oldPath: String,
        to newPath: String,
        workspaceId: UUID,
        in db: Database
    ) throws {
        guard let oldURL = workspaceURL(relativePath: oldPath),
              let newURL = workspaceURL(relativePath: newPath) else { return }
        try db.execute(
            sql: """
            UPDATE summary_exports
            SET url = ?, updatedAt = ?
            WHERE type = ?
              AND url = ?
              AND meetingId IN (SELECT id FROM meetings WHERE workspace_id = ?)
            """,
            arguments: [newURL, Date.now, SummaryExportType.workspace, oldURL, workspaceId]
        )
    }

    static func clearWorkspacePath(_ relativePath: String, workspaceId: UUID, in db: Database) throws {
        guard let url = workspaceURL(relativePath: relativePath) else { return }
        try db.execute(
            sql: """
            DELETE FROM summary_exports
            WHERE type = ?
              AND url = ?
              AND meetingId IN (SELECT id FROM meetings WHERE workspace_id = ?)
            """,
            arguments: [SummaryExportType.workspace, url, workspaceId]
        )
    }

}
