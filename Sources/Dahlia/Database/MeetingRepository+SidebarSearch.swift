import Foundation
import GRDB

extension MeetingRepository {
    nonisolated static func searchMeetingSidebarPage(
        vaultId: UUID,
        query: String,
        after cursor: MeetingSearchCursor? = nil,
        limit: Int,
        dbQueue: DatabaseQueue
    ) async throws -> MeetingSearchPage {
        try await searchMeetingSidebarPage(
            vaultId: vaultId,
            criteria: MeetingSearchCriteria(text: query),
            after: cursor,
            limit: limit,
            dbQueue: dbQueue
        )
    }

    nonisolated static func searchMeetingSidebarPage(
        vaultId: UUID,
        criteria: MeetingSearchCriteria,
        after cursor: MeetingSearchCursor? = nil,
        limit: Int,
        dbQueue: DatabaseQueue
    ) async throws -> MeetingSearchPage {
        try await withSearchDeadline {
            try await dbQueue.read { db in
                if criteria.text.isEmpty {
                    return try chronologicalSearch(
                        vaultId: vaultId,
                        criteria: criteria,
                        cursor: cursor,
                        limit: limit,
                        in: db
                    )
                }
                return try fullTextSearch(
                    vaultId: vaultId,
                    criteria: criteria,
                    cursor: cursor,
                    limit: limit,
                    in: db
                )
            }
        }
    }

    /// Both callers wrap GRDB async reads, whose task cancellation interrupts the active SQLite statement.
    private nonisolated static func withSearchDeadline<Result: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
        try await withThrowingTaskGroup(of: Result.self) { group in
            group.addTask(operation: operation)
            group.addTask {
                try await Task.sleep(for: .milliseconds(500))
                throw MeetingSearchError.queryTooBroad
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CancellationError() }
            return result
        }
    }

    nonisolated static func sidebarCursorFilter(
        _ cursor: MeetingSidebarCursor?
    ) -> (condition: String, arguments: StatementArguments) {
        guard let cursor else { return ("", []) }
        return (
            """
            AND (
                \(sidebarRecordingStartedAtSQL) < ?
                OR (\(sidebarRecordingStartedAtSQL) = ? AND meetings.id < ?)
            )
            """,
            [cursor.effectiveRecordingStartedAt, cursor.effectiveRecordingStartedAt, cursor.meetingId]
        )
    }

    private nonisolated static func fullTextSearch(
        vaultId: UUID,
        criteria: MeetingSearchCriteria,
        cursor: MeetingSearchCursor?,
        limit: Int,
        in db: Database
    ) throws -> MeetingSearchPage {
        let phase = try String.fetchOne(db, sql: "SELECT phase FROM search_index_state WHERE indexKind = 'fts'")
        guard phase != "failed" else { return .empty(replacesResults: cursor != nil) }

        let tokens = try fullTextTokens(for: criteria.text, in: db)
        guard !tokens.isEmpty else { return .empty(replacesResults: cursor != nil) }
        let revision = try Int.fetchOne(
            db,
            sql: "SELECT indexRevision FROM search_index_state WHERE indexKind = 'fts'"
        ) ?? 0
        let offset: Int
        let replacesResults: Bool
        if case let .relevance(cursorRevision, cursorOffset) = cursor, cursorRevision == revision {
            offset = cursorOffset
            replacesResults = false
        } else {
            offset = 0
            replacesResults = cursor != nil
        }

        let projects = try ProjectRecord.fetchResolvedAll(vaultId: vaultId, in: db)
        let includedProjects = descendantProjectIDs(selectedIDs: criteria.projectIDs, projects: projects)
        let filters = searchFilters(criteria: criteria, includedProjectIDs: includedProjects)
        let queryTokens = try orderedQueryTokens(tokens, in: db)
        let meetingIDs = try qualifyingMeetingIDs(
            queryTokens: queryTokens,
            vaultId: vaultId,
            filters: filters,
            in: db
        )
        let hits = try fullTextHits(queryTokens: queryTokens, meetingIDs: meetingIDs, in: db)
        let ranked = rankedMeetings(from: hits, requiredTokenCount: tokens.count)

        let window = Array(ranked.dropFirst(offset).prefix(limit + 1))
        let visible = Array(window.prefix(limit))
        let orderedIDs = visible.map(\.meetingID)
        var itemsByID = try Dictionary(
            uniqueKeysWithValues: fetchMeetingSidebarItems(ids: orderedIDs, vaultId: vaultId, in: db)
                .map { ($0.id, $0) }
        )
        for rank in visible {
            itemsByID[rank.meetingID]?.searchMatchContext = try matchContext(
                rank.evidence,
                meetingID: rank.meetingID,
                projects: projects,
                in: db
            )
        }
        let items = orderedIDs.compactMap { itemsByID[$0] }
        let hasMore = window.count > limit
        return MeetingSearchPage(
            items: items,
            groups: MeetingDateGrouping.searchResultGroups(from: items),
            hasMore: hasMore,
            nextCursor: hasMore ? .relevance(indexRevision: revision, offset: offset + visible.count) : nil,
            replacesResults: replacesResults
        )
    }

    private nonisolated static func fullTextHits(
        queryTokens: [FTSQueryToken],
        meetingIDs: [UUID],
        in db: Database
    ) throws -> [UUID: [Int: SearchTokenHit]] {
        guard !meetingIDs.isEmpty else { return [:] }
        var meetingHits: [UUID: [Int: SearchTokenHit]] = [:]
        for queryToken in queryTokens {
            try Task.checkCancellation()
            for field in SearchField.allCases {
                for start in stride(from: 0, to: meetingIDs.count, by: 200) {
                    try Task.checkCancellation()
                    let ids = Array(meetingIDs[start ..< min(start + 200, meetingIDs.count)])
                    var arguments = StatementArguments(ids)
                    arguments += ["\(field.rawValue) : \(queryToken.query)"]
                    let rows = try Row.fetchAll(
                        db,
                        sql: """
                        WITH candidate_documents AS MATERIALIZED (
                            SELECT id, meetingId,
                                   CASE WHEN kind = 'segment' THEN sourceId END AS segmentId,
                                   segmentStart
                            FROM search_documents
                            WHERE kind IN ('meeting', 'segment')
                              AND meetingId IN (\(searchPlaceholders(ids.count)))
                        )
                        SELECT candidate_documents.meetingId AS meetingId,
                               candidate_documents.segmentId AS segmentId,
                               candidate_documents.segmentStart AS segmentStart,
                               \(sidebarRecordingStartedAtSQL) AS meetingDate,
                               -bm25(search_documents_fts) AS relevance
                        FROM candidate_documents
                        CROSS JOIN search_documents_fts
                        JOIN meetings ON meetings.id = candidate_documents.meetingId
                        WHERE search_documents_fts.rowid = candidate_documents.id
                          AND search_documents_fts MATCH ?
                        """,
                        arguments: arguments
                    )
                    merge(
                        rows: rows,
                        token: queryToken.token,
                        field: field,
                        ordinal: queryToken.ordinal,
                        into: &meetingHits
                    )
                }
            }
        }
        return meetingHits
    }

    private nonisolated static func orderedQueryTokens(_ tokens: [String], in db: Database) throws -> [FTSQueryToken] {
        try tokens.enumerated().map { ordinal, token in
            let isPrefix = ordinal == tokens.count - 1
            let estimatedDocuments: Int = if isPrefix {
                try Int.fetchOne(
                    db,
                    sql: """
                    SELECT COALESCE(SUM(doc), 0) FROM search_documents_fts_vocab
                    WHERE term >= ? AND term < ?
                    """,
                    arguments: [token, token + "\u{10FFFF}"]
                ) ?? 0
            } else {
                try Int.fetchOne(
                    db,
                    sql: "SELECT doc FROM search_documents_fts_vocab WHERE term = ?",
                    arguments: [token]
                ) ?? 0
            }
            return FTSQueryToken(
                ordinal: ordinal,
                token: token,
                query: quotedFTSToken(token, isPrefix: isPrefix),
                estimatedDocuments: estimatedDocuments
            )
        }.sorted {
            if $0.estimatedDocuments != $1.estimatedDocuments {
                return $0.estimatedDocuments < $1.estimatedDocuments
            }
            return $0.token.count > $1.token.count
        }
    }

    private nonisolated static func qualifyingMeetingIDs(
        queryTokens: [FTSQueryToken],
        vaultId: UUID,
        filters: (condition: String, arguments: StatementArguments),
        in db: Database
    ) throws -> [UUID] {
        guard let seed = queryTokens.first else { return [] }
        let remaining = queryTokens.dropFirst()
        let requirements = remaining.map { _ in
            """
            EXISTS (
                SELECT 1
                FROM search_documents AS matching_documents
                CROSS JOIN search_documents_fts
                WHERE matching_documents.meetingId = seed_documents.meetingId
                  AND matching_documents.kind IN ('meeting', 'segment')
                  AND search_documents_fts.rowid = matching_documents.id
                  AND search_documents_fts MATCH ?
            )
            """
        }.joined(separator: " AND ")
        var arguments: StatementArguments = [seed.query, vaultId]
        arguments += filters.arguments
        arguments += StatementArguments(remaining.map(\.query))
        return try UUID.fetchAll(
            db,
            sql: """
            WITH seed_documents AS MATERIALIZED (
                SELECT search_documents.meetingId AS meetingId
                FROM search_documents_fts
                JOIN search_documents ON search_documents.id = search_documents_fts.rowid
                JOIN meetings ON meetings.id = search_documents.meetingId
                WHERE search_documents_fts MATCH ?
                  AND search_documents.vaultId = ?
                  AND search_documents.kind IN ('meeting', 'segment')
                  \(filters.condition)
                GROUP BY search_documents.meetingId
            )
            SELECT seed_documents.meetingId
            FROM seed_documents
            \(requirements.isEmpty ? "" : "WHERE \(requirements)")
            """,
            arguments: arguments
        )
    }

    private nonisolated static func merge(
        rows: [Row],
        token: String,
        field: SearchField,
        ordinal: Int,
        into meetingHits: inout [UUID: [Int: SearchTokenHit]]
    ) {
        for row in rows {
            let meetingID: UUID = row["meetingId"]
            let hit = SearchTokenHit(
                token: token,
                field: field,
                relevance: row["relevance"],
                segmentID: row["segmentId"],
                segmentStart: row["segmentStart"],
                meetingDate: row["meetingDate"]
            )
            if let current = meetingHits[meetingID]?[ordinal] {
                guard hit.field.matchClass < current.field.matchClass
                    || (hit.field.matchClass == current.field.matchClass && hit.relevance > current.relevance)
                else { continue }
            }
            meetingHits[meetingID, default: [:]][ordinal] = hit
        }
    }

    private nonisolated static func rankedMeetings(
        from meetingHits: [UUID: [Int: SearchTokenHit]],
        requiredTokenCount: Int
    ) -> [RankedMeeting] {
        meetingHits.compactMap { meetingID, hitsByOrdinal -> RankedMeeting? in
            guard hitsByOrdinal.count == requiredTokenCount else { return nil }
            let hits = hitsByOrdinal.keys.sorted().compactMap { hitsByOrdinal[$0] }
            guard let evidence = hits.max(by: { lhs, rhs in
                if lhs.field.matchClass != rhs.field.matchClass {
                    return lhs.field.matchClass < rhs.field.matchClass
                }
                return lhs.relevance < rhs.relevance
            }) else { return nil }
            return RankedMeeting(
                meetingID: meetingID,
                matchClass: hits.map(\.field.matchClass).max() ?? 3,
                relevance: hits.map(\.relevance).min() ?? 0,
                meetingDate: hits.first?.meetingDate ?? .distantPast,
                evidence: evidence
            )
        }.sorted { lhs, rhs in
            if lhs.matchClass != rhs.matchClass { return lhs.matchClass < rhs.matchClass }
            if lhs.relevance != rhs.relevance { return lhs.relevance > rhs.relevance }
            if lhs.meetingDate != rhs.meetingDate { return lhs.meetingDate > rhs.meetingDate }
            return lhs.meetingID.uuidString < rhs.meetingID.uuidString
        }
    }

    private nonisolated static func chronologicalSearch(
        vaultId: UUID,
        criteria: MeetingSearchCriteria,
        cursor: MeetingSearchCursor?,
        limit: Int,
        in db: Database
    ) throws -> MeetingSearchPage {
        let chronologicalCursor: MeetingSidebarCursor? = if case let .chronological(value) = cursor { value } else {
            nil
        }
        let projects = try ProjectRecord.fetchResolvedAll(vaultId: vaultId, in: db)
        let paths = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0.path) })
        let includedProjects = descendantProjectIDs(selectedIDs: criteria.projectIDs, projects: projects)
        let filters = searchFilters(criteria: criteria, includedProjectIDs: includedProjects)
        let cursorFilter = sidebarCursorFilter(chronologicalCursor)
        var arguments: StatementArguments = [vaultId]
        arguments += filters.arguments
        arguments += cursorFilter.arguments
        arguments += [limit + 1]
        var items = try MeetingSidebarItem.fetchAll(
            db,
            sql: """
            SELECT meetings.id AS meetingId, meetings.vaultId AS vaultId,
                   meetings.projectId AS projectId, NULL AS projectName,
                   meetings.name AS meetingName, meetings.status AS status,
                   meetings.duration AS duration, meetings.createdAt AS createdAt,
                   meetings.recordingStartedAt AS recordingStartedAt,
                   calendar_events.title AS calendarEventTitle
            FROM meetings LEFT JOIN calendar_events
              ON calendar_events.ical_uid = meetings.calendar_event_ical_uid
             AND calendar_events.recurrence_id = meetings.calendar_event_recurrence_id
            WHERE meetings.vaultId = ? \(filters.condition) \(cursorFilter.condition)
            ORDER BY \(sidebarRecordingStartedAtSQL) DESC, meetings.id DESC LIMIT ?
            """,
            arguments: arguments
        )
        let hasMore = items.count > limit
        if hasMore { items.removeLast() }
        for index in items.indices {
            items[index].projectName = items[index].projectId.flatMap { paths[$0] }
        }
        return MeetingSearchPage(
            items: items,
            groups: MeetingDateGrouping.groups(from: items),
            hasMore: hasMore,
            nextCursor: items.last.map { .chronological(MeetingSidebarCursor(item: $0)) },
            replacesResults: cursor != nil && chronologicalCursor == nil
        )
    }

    private nonisolated static func searchFilters(
        criteria: MeetingSearchCriteria,
        includedProjectIDs: Set<UUID>
    ) -> (condition: String, arguments: StatementArguments) {
        var conditions: [String] = []
        var arguments: StatementArguments = []
        if let start = criteria.startDate {
            conditions.append("\(sidebarRecordingStartedAtSQL) >= ?")
            arguments += [start]
        }
        if let end = criteria.endDate {
            conditions.append("\(sidebarRecordingStartedAtSQL) < ?")
            arguments += [end]
        }
        if !criteria.projectIDs.isEmpty {
            conditions.append("meetings.projectId IN (\(searchPlaceholders(includedProjectIDs.count)))")
            arguments += StatementArguments(includedProjectIDs.sorted { $0.uuidString < $1.uuidString })
        }
        if !criteria.tagIDs.isEmpty {
            conditions.append(
                """
                EXISTS (SELECT 1 FROM meeting_tags smt WHERE smt.meetingId = meetings.id
                        AND smt.tagId IN (\(searchPlaceholders(criteria.tagIDs.count))))
                """
            )
            arguments += StatementArguments(criteria.tagIDs.sorted())
        }
        return (conditions.map { "AND \($0)" }.joined(separator: "\n"), arguments)
    }

    private nonisolated static func descendantProjectIDs(
        selectedIDs: Set<UUID>,
        projects: [ProjectRecord]
    ) -> Set<UUID> {
        var result = selectedIDs
        guard !result.isEmpty else { return result }
        var changed = true
        while changed {
            changed = false
            for project in projects where project.parentProjectId.map(result.contains) == true {
                changed = result.insert(project.id).inserted || changed
            }
        }
        return result
    }

    private nonisolated static func matchContext(
        _ hit: SearchTokenHit,
        meetingID: UUID,
        projects: [ProjectRecord],
        in db: Database
    ) throws -> MeetingSearchMatchContext {
        switch hit.field {
        case .title:
            return try .init(kind: .title, text: meetingText("name", meetingID: meetingID, in: db))
        case .description:
            return try .init(kind: .description, text: meetingText("description", meetingID: meetingID, in: db))
        case .calendar:
            let calendar = try Row.fetchOne(
                db,
                sql: """
                SELECT calendar_events.title, calendar_events.description
                FROM meetings JOIN calendar_events
                  ON calendar_events.ical_uid = meetings.calendar_event_ical_uid
                 AND calendar_events.recurrence_id = meetings.calendar_event_recurrence_id
                WHERE meetings.id = ?
                """,
                arguments: [meetingID]
            )
            let value = [calendar?["title"] as String?, calendar?["description"] as String?]
                .compactMap(\.self)
                .joined(separator: " ")
            return .init(kind: .calendar, text: value)
        case .tags:
            let value = try String.fetchAll(
                db,
                sql: "SELECT tags.name FROM tags JOIN meeting_tags ON tags.id = meeting_tags.tagId WHERE meeting_tags.meetingId = ?",
                arguments: [meetingID]
            ).joined(separator: ", ")
            return .init(kind: .tag, text: value)
        case .projectPath:
            let projectID = try UUID.fetchOne(db, sql: "SELECT projectId FROM meetings WHERE id = ?", arguments: [meetingID])
            return .init(kind: .project, text: projectID.flatMap { id in projects.first { $0.id == id }?.path } ?? "")
        case .transcript:
            let text = try hit.segmentID.flatMap {
                try String.fetchOne(db, sql: "SELECT text FROM transcript_segments WHERE id = ?", arguments: [$0])
            } ?? ""
            return .init(
                kind: .transcript,
                text: transcriptSnippet(text, matching: hit.token),
                segmentId: hit.segmentID,
                timestamp: hit.segmentStart
            )
        }
    }

    private nonisolated static func transcriptSnippet(_ text: String, matching token: String) -> String {
        let maximumLength = 180
        guard text.count > maximumLength else { return text }
        guard let match = text.range(
            of: token,
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        ) else {
            return String(text.prefix(maximumLength))
        }
        let start = text.index(match.lowerBound, offsetBy: -60, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(start, offsetBy: maximumLength, limitedBy: text.endIndex) ?? text.endIndex
        return "\(start == text.startIndex ? "" : "…")\(text[start ..< end])\(end == text.endIndex ? "" : "…")"
    }

    private nonisolated static func meetingText(
        _ column: String,
        meetingID: UUID,
        in db: Database
    ) throws -> String {
        try String.fetchOne(db, sql: "SELECT \(column) FROM meetings WHERE id = ?", arguments: [meetingID]) ?? ""
    }

    private nonisolated static func quotedFTSToken(_ token: String, isPrefix: Bool) -> String {
        "\"\(token.replacingOccurrences(of: "\"", with: "\"\""))\"\(isPrefix ? "*" : "")"
    }

    private nonisolated static func fullTextTokens(for query: String, in db: Database) throws -> [String] {
        guard query.count >= 2 else { return [] }
        let tokenizer = try db.makeTokenizer(SearchFTS5Tokenizer.tokenizerDescriptor())
        return try Array(tokenizer.tokenize(query: query).prefix(16).map(\.token))
    }

    private nonisolated static func searchPlaceholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ",")
    }

}

extension MeetingRepository {
    nonisolated static func searchProjectIDs(
        vaultID: UUID,
        query: String,
        limit: Int,
        dbQueue: DatabaseQueue
    ) async throws -> [UUID] {
        try await withSearchDeadline {
            try await dbQueue.read { db in
                try searchProjectIDs(vaultID: vaultID, query: query, limit: limit, in: db)
            }
        }
    }

    private nonisolated static func searchProjectIDs(
        vaultID: UUID,
        query: String,
        limit: Int,
        in db: Database
    ) throws -> [UUID] {
        let phase = try String.fetchOne(db, sql: "SELECT phase FROM search_index_state WHERE indexKind = 'fts'")
        guard phase != "failed" else { return [] }
        let tokens = try fullTextTokens(for: query, in: db)
        guard !tokens.isEmpty else { return [] }
        let tokenQuery = tokens.enumerated().map { ordinal, token in
            quotedFTSToken(token, isPrefix: ordinal == tokens.count - 1)
        }.joined(separator: " AND ")
        let columnScopes = ["title", "{title projectPath}", "{title projectPath description}"]
        var projectIDs: [UUID] = []
        var seenProjectIDs: Set<UUID> = []
        for columnScope in columnScopes {
            try Task.checkCancellation()
            let ids = try UUID.fetchAll(
                db,
                sql: """
                SELECT search_documents.projectId
                FROM search_documents_fts
                JOIN search_documents ON search_documents.id = search_documents_fts.rowid
                WHERE search_documents_fts MATCH ?
                  AND search_documents.vaultId = ? AND search_documents.kind = 'project'
                ORDER BY bm25(search_documents_fts), search_documents.projectId
                LIMIT ?
                """,
                arguments: ["\(columnScope) : (\(tokenQuery))", vaultID, limit]
            )
            for id in ids where seenProjectIDs.insert(id).inserted {
                projectIDs.append(id)
                if projectIDs.count == limit { return projectIDs }
            }
        }
        return projectIDs
    }
}

private enum SearchField: String, CaseIterable {
    case title, tags, projectPath, calendar, description, transcript

    var matchClass: Int {
        switch self {
        case .title: 0
        case .tags, .projectPath, .calendar: 1
        case .description: 2
        case .transcript: 3
        }
    }
}

private struct FTSQueryToken {
    let ordinal: Int
    let token: String
    let query: String
    let estimatedDocuments: Int
}

private struct SearchTokenHit {
    let token: String
    let field: SearchField
    let relevance: Double
    let segmentID: UUID?
    let segmentStart: Date?
    let meetingDate: Date

}

private struct RankedMeeting {
    let meetingID: UUID
    let matchClass: Int
    let relevance: Double
    let meetingDate: Date
    let evidence: SearchTokenHit
}

private extension MeetingSearchPage {
    static func empty(replacesResults: Bool) -> Self {
        Self(items: [], groups: [], hasMore: false, nextCursor: nil, replacesResults: replacesResults)
    }
}

private enum MeetingSearchError: LocalizedError {
    case queryTooBroad

    var errorDescription: String? {
        L10n.searchQueryTooBroad
    }
}
