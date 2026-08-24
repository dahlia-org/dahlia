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
            let tokenQuery = tokens.enumerated().map { index, token in
                SearchFTS5Tokenizer.quotedQueryToken(token, isPrefix: index == tokens.count - 1)
            }.joined(separator: " AND ")
            let combinedQuery = "{ocr caption} : (\(tokenQuery))"
            let fullOCRQuery = "ocr : (\(tokenQuery))"
            let fullCaptionQuery = "caption : (\(tokenQuery))"
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
            var arguments: StatementArguments = [combinedQuery, fullOCRQuery, fullCaptionQuery, vaultID]
            arguments += filter.arguments
            arguments += [limit + 1, offset]
            var rows = try Row.fetchAll(
                db,
                sql: """
                WITH combined_matches AS (
                    SELECT rowid, bm25(search_documents_fts) AS relevance
                    FROM search_documents_fts
                    WHERE search_documents_fts MATCH ?
                ),
                full_ocr_matches AS (
                    SELECT rowid FROM search_documents_fts
                    WHERE search_documents_fts MATCH ?
                ),
                full_caption_matches AS (
                    SELECT rowid FROM search_documents_fts
                    WHERE search_documents_fts MATCH ?
                )
                SELECT screenshots.id, screenshots.meetingId, screenshots.capturedAt,
                       screenshots.mimeType, screenshots.ocrText, screenshots.caption,
                       meetings.name AS meetingTitle, meetings.description AS meetingDescription,
                       full_ocr_matches.rowid IS NOT NULL AS fullOCRMatch,
                       full_caption_matches.rowid IS NOT NULL AS fullCaptionMatch,
                       CASE WHEN full_ocr_matches.rowid IS NOT NULL THEN 0
                            WHEN full_caption_matches.rowid IS NULL THEN 1
                            ELSE 2 END AS matchTier
                FROM combined_matches
                JOIN search_documents ON search_documents.id = combined_matches.rowid
                JOIN screenshots ON screenshots.id = search_documents.sourceId
                JOIN meetings ON meetings.id = screenshots.meetingId
                LEFT JOIN full_ocr_matches ON full_ocr_matches.rowid = combined_matches.rowid
                LEFT JOIN full_caption_matches ON full_caption_matches.rowid = combined_matches.rowid
                WHERE search_documents.kind = 'screenshot'
                  AND search_documents.vaultId = ?
                  \(filter.condition)
                ORDER BY matchTier, combined_matches.relevance, screenshots.capturedAt DESC, screenshots.id
                LIMIT ? OFFSET ?
                """,
                arguments: arguments
            )
            let hasMore = rows.count > limit
            if hasMore { rows.removeLast() }
            let snippetTokenizer = try db.makeTokenizer(SearchFTS5Tokenizer.tokenizerDescriptor())
            let items = try rows.map {
                try screenshotSearchResult(
                    row: $0,
                    query: criteria.text,
                    tokens: tokens,
                    tokenizer: snippetTokenizer
                )
            }
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
        try await dbQueue.read { db in
            try Data.fetchOne(
                db,
                sql: """
                SELECT screenshots.imageData
                FROM screenshots
                JOIN meetings ON meetings.id = screenshots.meetingId
                WHERE screenshots.id = ? AND meetings.vaultId = ?
                """,
                arguments: [id, vaultID]
            )
        }
    }

    private nonisolated static func screenshotSearchResult(
        row: Row,
        query: String,
        tokens: [String],
        tokenizer: any FTS5Tokenizer
    ) throws -> ScreenshotSearchResult {
        let ocrText: String = row["ocrText"]
        let caption: String = row["caption"]
        let matchTier: Int = row["matchTier"]
        let fullOCRMatch: Bool = row["fullOCRMatch"]
        let fullCaptionMatch: Bool = row["fullCaptionMatch"]
        var matches: [ScreenshotSearchMatch] = []
        if fullOCRMatch || matchTier == 1 {
            try matches.append(.init(
                source: .ocr,
                snippet: screenshotSnippet(ocrText, query: query, tokens: tokens, tokenizer: tokenizer)
            ))
        }
        if fullCaptionMatch || matchTier == 1 {
            try matches.append(.init(
                source: .caption,
                snippet: screenshotSnippet(caption, query: query, tokens: tokens, tokenizer: tokenizer)
            ))
        }
        return ScreenshotSearchResult(
            id: row["id"],
            meetingID: row["meetingId"],
            meetingTitle: row["meetingTitle"],
            meetingDescription: row["meetingDescription"],
            capturedAt: row["capturedAt"],
            mimeType: row["mimeType"],
            matches: matches
        )
    }

    private nonisolated static func screenshotSnippet(
        _ text: String,
        query: String,
        tokens: [String],
        tokenizer: any FTS5Tokenizer
    ) throws -> String {
        if let match = text.range(
            of: query,
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: .current
        ) {
            return snippet(text, around: match)
        }
        if let match = try SearchFTS5Tokenizer.firstDocumentTokenRange(
            in: text,
            matching: tokens,
            using: tokenizer
        ) {
            return snippet(text, around: match)
        }
        return snippet(text, matching: query)
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
