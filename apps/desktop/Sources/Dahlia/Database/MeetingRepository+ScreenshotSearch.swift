import DahliaMeetingAccess
import Foundation
import GRDB

extension MeetingRepository {
    nonisolated static func searchScreenshotPage(
        vaultID: UUID,
        criteria: MeetingSearchCriteria,
        after cursor: ScreenshotSearchCursor? = nil,
        limit: Int,
        dbQueue: DatabaseQueue
    ) async throws -> ScreenshotSearchPage {
        try await dbQueue.read { db in
            guard !criteria.text.isEmpty else { return ScreenshotSearchPage(items: [], nextCursor: nil, replacesResults: false) }
            let phase = try String.fetchOne(
                db,
                sql: "SELECT phase FROM search_index_state WHERE indexKind = 'fts'"
            )
            guard phase == "ready" else { throw MeetingSearchError.indexUnavailable }
            let tokens = try SearchFTS5Tokenizer.queryTokens(for: criteria.text, in: db)
            guard !tokens.isEmpty else { return ScreenshotSearchPage(items: [], nextCursor: nil, replacesResults: false) }
            let query = "{ocr caption} : (" + tokens.enumerated().map { index, token in
                SearchFTS5Tokenizer.quotedQueryToken(token, isPrefix: index == tokens.count - 1)
            }.joined(separator: " AND ") + ")"
            let revision = try Int.fetchOne(
                db,
                sql: "SELECT indexRevision FROM search_index_state WHERE indexKind = 'fts'"
            ) ?? 0
            let replacesResults = cursor.map { $0.indexRevision != revision } ?? false
            let offset = replacesResults ? 0 : cursor?.offset ?? 0
            let projects = try ProjectRecord.fetchResolvedAll(vaultId: vaultID, in: db)
            let includedProjectIDs = screenshotDescendantProjectIDs(
                selectedIDs: criteria.projectIDs,
                projects: projects
            )
            let filter = screenshotSearchFilter(criteria, includedProjectIDs: includedProjectIDs)
            var arguments: StatementArguments = [vaultID, query]
            arguments += filter.arguments
            arguments += [limit + 1, offset]
            var rows = try Row.fetchAll(
                db,
                sql: """
                SELECT screenshots.id, screenshots.meetingId, screenshots.capturedAt,
                       screenshots.mimeType, screenshots.ocrText, screenshots.caption,
                       meetings.name AS meetingTitle, meetings.description AS meetingDescription
                FROM search_documents
                JOIN search_documents_fts ON search_documents_fts.rowid = search_documents.id
                JOIN screenshots ON screenshots.id = search_documents.sourceId
                JOIN meetings ON meetings.id = screenshots.meetingId
                WHERE search_documents.kind = 'screenshot'
                  AND search_documents.vaultId = ?
                  AND search_documents_fts MATCH ?
                  \(filter.condition)
                ORDER BY \(SearchFTS5Tokenizer.screenshotRankingSQL), screenshots.capturedAt DESC, screenshots.id
                LIMIT ? OFFSET ?
                """,
                arguments: arguments
            )
            let hasMore = rows.count > limit
            if hasMore { rows.removeLast() }
            let items = rows.map { screenshotSearchResult(row: $0) }
            return ScreenshotSearchPage(
                items: items,
                nextCursor: hasMore ? ScreenshotSearchCursor(
                    indexRevision: revision,
                    offset: offset + items.count
                ) : nil,
                replacesResults: replacesResults
            )
        }
    }

    nonisolated static func screenshotImageData(
        id: UUID,
        vaultID: UUID,
        dbQueue: DatabaseQueue
    ) async throws -> Data? {
        let exists = try await dbQueue.read { db in
            try Bool.fetchOne(
                db,
                sql: """
                SELECT EXISTS(SELECT 1
                FROM screenshots
                JOIN meetings ON meetings.id = screenshots.meetingId
                WHERE screenshots.id = ? AND meetings.vaultId = ?)
                """,
                arguments: [id, vaultID]
            )
        }
        guard exists == true else { return nil }
        return try await ScreenshotContentProvider.shared.content(id: id, variant: .thumbnail, dbQueue: dbQueue).data
    }

    private nonisolated static func screenshotSearchResult(row: Row) -> ScreenshotSearchResult {
        ScreenshotSearchResult(
            id: row["id"],
            meetingID: row["meetingId"],
            meetingTitle: row["meetingTitle"],
            meetingDescription: row["meetingDescription"],
            capturedAt: row["capturedAt"],
            mimeType: row["mimeType"],
            snippet: String(
                [row["caption"] as String, row["ocrText"] as String]
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                    .prefix(180)
            )
        )
    }

    private nonisolated static func screenshotSearchFilter(
        _ criteria: MeetingSearchCriteria,
        includedProjectIDs: Set<UUID>
    ) -> (condition: String, arguments: StatementArguments) {
        var conditions: [String] = []
        var arguments: StatementArguments = []
        if let startDate = criteria.startDate {
            conditions.append("COALESCE(meetings.recordingStartedAt, meetings.createdAt) >= ?")
            arguments += [startDate]
        }
        if let endDate = criteria.endDate {
            conditions.append("COALESCE(meetings.recordingStartedAt, meetings.createdAt) < ?")
            arguments += [endDate]
        }
        if !criteria.projectIDs.isEmpty {
            let placeholders = Array(repeating: "?", count: includedProjectIDs.count).joined(separator: ",")
            conditions.append("meetings.projectId IN (\(placeholders))")
            arguments += StatementArguments(includedProjectIDs.sorted { $0.uuidString < $1.uuidString })
        }
        if !criteria.tagIDs.isEmpty {
            let placeholders = Array(repeating: "?", count: criteria.tagIDs.count).joined(separator: ",")
            conditions.append("""
            EXISTS (SELECT 1 FROM meeting_tags
                    WHERE meeting_tags.meetingId = meetings.id
                      AND meeting_tags.tagId IN (\(placeholders)))
            """)
            arguments += StatementArguments(criteria.tagIDs.sorted())
        }
        return (conditions.map { "AND \($0)" }.joined(separator: "\n"), arguments)
    }

    private nonisolated static func screenshotDescendantProjectIDs(
        selectedIDs: Set<UUID>,
        projects: [ProjectRecord]
    ) -> Set<UUID> {
        var result = selectedIDs
        var changed = !result.isEmpty
        while changed {
            changed = false
            for project in projects where project.parentProjectId.map(result.contains) == true {
                changed = result.insert(project.id).inserted || changed
            }
        }
        return result
    }
}
