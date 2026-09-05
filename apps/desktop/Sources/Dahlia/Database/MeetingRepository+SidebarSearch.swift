import DahliaMeetingAccess
import Foundation
import GRDB

extension MeetingRepository {
    nonisolated static func searchMeetingSidebarPage(
        vaultId: UUID,
        query: String,
        rankingPolicy: MeetingSearchRankingPolicy = .standard,
        after cursor: MeetingSearchCursor? = nil,
        limit: Int,
        dbQueue: DatabaseQueue
    ) async throws -> MeetingSearchPage {
        try await searchMeetingSidebarPage(
            vaultId: vaultId,
            criteria: MeetingSearchCriteria(text: query),
            rankingPolicy: rankingPolicy,
            after: cursor,
            limit: limit,
            dbQueue: dbQueue
        )
    }

    nonisolated static func searchMeetingSidebarPage(
        vaultId: UUID,
        criteria: MeetingSearchCriteria,
        rankingPolicy: MeetingSearchRankingPolicy = .standard,
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
                    policy: rankingPolicy,
                    cursor: cursor,
                    limit: limit,
                    in: db
                )
            }
        }
    }

    private nonisolated static func withSearchDeadline<Result: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
        try await withThrowingTaskGroup(of: Result.self) { group in
            group.addTask(operation: operation)
            group.addTask {
                try await Task.sleep(for: .seconds(30))
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
        policy: MeetingSearchRankingPolicy,
        cursor: MeetingSearchCursor?,
        limit: Int,
        in db: Database
    ) throws -> MeetingSearchPage {
        try requireReadySearchIndex(in: db)

        let tokens = try SearchFTS5Tokenizer.queryTokens(for: criteria.text, in: db)
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

        let includedProjects = try includedProjectIDs(for: criteria, vaultId: vaultId, in: db)
        let filters = searchFilters(criteria: criteria, includedProjectIDs: includedProjects)
        let queryTokens = try orderedQueryTokens(tokens, in: db)
        let meetingIDs = try qualifyingMeetingIDs(
            queryTokens: queryTokens,
            vaultId: vaultId,
            policy: policy,
            filters: filters,
            in: db
        )
        let hits = try fullTextHits(
            queryTokens: queryTokens,
            meetingIDs: meetingIDs,
            policy: policy,
            in: db
        )
        let ranked = rankedMeetings(from: hits)

        let window = Array(ranked.dropFirst(offset).prefix(limit + 1))
        let visible = Array(window.prefix(limit))
        let orderedIDs = visible.map(\.meetingID)
        var itemsByID = try Dictionary(
            uniqueKeysWithValues: fetchMeetingSidebarItems(ids: orderedIDs, vaultId: vaultId, in: db)
                .map { ($0.id, $0) }
        )
        let fieldsByMeeting = try matchedFields(
            meetingIDs: orderedIDs,
            queryTokens: queryTokens,
            policy: policy,
            in: db
        )
        for id in orderedIDs {
            itemsByID[id]?.searchMatchContext = try matchContext(
                field: fieldsByMeeting[id] ?? .title,
                tokens: tokens,
                meetingID: id,
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

    /// 候補 meeting を全 token の AND で一度だけ採点する。
    /// 順位は設定された重みを BM25 のカラム重みとして与えた単一のスコアで決まる。
    private nonisolated static func fullTextHits(
        queryTokens: [FTSQueryToken],
        meetingIDs: [UUID],
        policy: MeetingSearchRankingPolicy,
        in db: Database
    ) throws -> [UUID: SearchHit] {
        guard !meetingIDs.isEmpty else { return [:] }
        let expression = policy.matchExpression(conjunction(of: queryTokens))
        var meetingHits: [UUID: SearchHit] = [:]
        for start in stride(from: 0, to: meetingIDs.count, by: 200) {
            try Task.checkCancellation()
            let ids = Array(meetingIDs[start ..< min(start + 200, meetingIDs.count)])
            var arguments = StatementArguments(ids)
            arguments += [expression]
            let rows = try Row.fetchAll(
                db,
                sql: """
                WITH candidate_documents AS MATERIALIZED (
                    SELECT id, meetingId
                    FROM search_documents
                    WHERE kind = 'meeting'
                      AND meetingId IN (\(searchPlaceholders(ids.count)))
                )
                SELECT candidate_documents.meetingId AS meetingId,
                       \(sidebarRecordingStartedAtSQL) AS meetingDate,
                       -\(policy.bm25RankingSQL) AS relevance
                FROM candidate_documents
                CROSS JOIN search_documents_fts
                JOIN meetings ON meetings.id = candidate_documents.meetingId
                WHERE search_documents_fts.rowid = candidate_documents.id
                  AND search_documents_fts MATCH ?
                """,
                arguments: arguments
            )
            for row in rows {
                let meetingID: UUID = row["meetingId"]
                meetingHits[meetingID] = SearchHit(
                    relevance: row["relevance"],
                    meetingDate: row["meetingDate"]
                )
            }
        }
        return meetingHits
    }

    /// 表示するページの各 meeting について、どのフィールドで一致したかを重みの高い順に判定する。
    /// 候補全件ではなくページ内の meeting だけを対象にする。
    private nonisolated static func matchedFields(
        meetingIDs: [UUID],
        queryTokens: [FTSQueryToken],
        policy: MeetingSearchRankingPolicy,
        in db: Database
    ) throws -> [UUID: MeetingSearchField] {
        guard !meetingIDs.isEmpty else { return [:] }
        let disjunction = queryTokens
            .sorted { $0.ordinal < $1.ordinal }
            .map(\.query)
            .joined(separator: " OR ")
        var resolved: [UUID: MeetingSearchField] = [:]
        for field in policy.rankedFields {
            guard resolved.count < meetingIDs.count else { break }
            try Task.checkCancellation()
            let pending = meetingIDs.filter { resolved[$0] == nil }
            var arguments = StatementArguments(pending)
            arguments += ["{\(field.rawValue)} : (\(disjunction))"]
            let matched = try UUID.fetchAll(
                db,
                sql: """
                WITH candidate_documents AS MATERIALIZED (
                    SELECT id, meetingId
                    FROM search_documents
                    WHERE kind = 'meeting'
                      AND meetingId IN (\(searchPlaceholders(pending.count)))
                )
                SELECT candidate_documents.meetingId
                FROM candidate_documents
                CROSS JOIN search_documents_fts
                WHERE search_documents_fts.rowid = candidate_documents.id
                  AND search_documents_fts MATCH ?
                """,
                arguments: arguments
            )
            for id in matched {
                resolved[id] = field
            }
        }
        return resolved
    }

    private nonisolated static func conjunction(of queryTokens: [FTSQueryToken]) -> String {
        queryTokens
            .sorted { $0.ordinal < $1.ordinal }
            .map(\.query)
            .joined(separator: " AND ")
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
                query: SearchFTS5Tokenizer.quotedQueryToken(token, isPrefix: isPrefix),
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
        policy: MeetingSearchRankingPolicy,
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
                  AND matching_documents.kind = 'meeting'
                  AND search_documents_fts.rowid = matching_documents.id
                  AND search_documents_fts MATCH ?
            )
            """
        }.joined(separator: " AND ")
        var arguments: StatementArguments = [policy.matchExpression(seed.query), vaultId]
        arguments += filters.arguments
        arguments += StatementArguments(remaining.map { policy.matchExpression($0.query) })
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
                  AND search_documents.kind = 'meeting'
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

    private nonisolated static func rankedMeetings(from meetingHits: [UUID: SearchHit]) -> [RankedMeeting] {
        meetingHits.map { meetingID, hit in
            RankedMeeting(meetingID: meetingID, relevance: hit.relevance, meetingDate: hit.meetingDate)
        }.sorted { lhs, rhs in
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

    private nonisolated static func includedProjectIDs(
        for criteria: MeetingSearchCriteria,
        vaultId: UUID,
        in db: Database
    ) throws -> Set<UUID> {
        guard !criteria.projectIDs.isEmpty else { return [] }
        let projects = try ProjectRecord.fetchResolvedAll(vaultId: vaultId, in: db)
        return descendantProjectIDs(selectedIDs: criteria.projectIDs, projects: projects)
    }

    private nonisolated static func matchContext(
        field: MeetingSearchField,
        tokens: [String],
        meetingID: UUID,
        in db: Database
    ) throws -> MeetingSearchMatchContext {
        switch field {
        case .title:
            return try .init(kind: .title, text: meetingText("name", meetingID: meetingID, in: db))
        case .description:
            return try .init(
                kind: .description,
                text: snippet(meetingText("description", meetingID: meetingID, in: db), matching: tokens)
            )
        case .summary:
            return try .init(
                kind: .summary,
                text: snippet(summaryBodyText(meetingID: meetingID, in: db), matching: tokens)
            )
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
            let tags = try Row.fetchAll(
                db,
                sql: """
                SELECT tags.name, tags.colorHex
                FROM tags JOIN meeting_tags ON tags.id = meeting_tags.tagId
                WHERE meeting_tags.meetingId = ? ORDER BY tags.id
                """,
                arguments: [meetingID]
            )
            let tag = tags.first(where: { row in
                let name: String = row["name"]
                return tokens.contains { name.localizedStandardContains($0) }
            }) ?? tags.first
            return .init(kind: .tag, text: tag?["name"] ?? "", colorHex: tag?["colorHex"])
        }
    }

    private nonisolated static func meetingText(
        _ column: String,
        meetingID: UUID,
        in db: Database
    ) throws -> String {
        try String.fetchOne(db, sql: "SELECT \(column) FROM meetings WHERE id = ?", arguments: [meetingID]) ?? ""
    }

    private nonisolated static func summaryBodyText(meetingID: UUID, in db: Database) throws -> String {
        try SummaryRecord.fetchOne(db, key: meetingID)
            .flatMap { try? $0.loadDocument().searchableBodyText } ?? ""
    }

    private nonisolated static func snippet(_ text: String, matching tokens: [String]) -> String {
        let maximumLength = 180
        guard text.count > maximumLength else { return text }
        guard let match = tokens.lazy.compactMap({ token in
            text.range(of: token, options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        }).min(by: { $0.lowerBound < $1.lowerBound })
        else { return String(text.prefix(maximumLength)) }
        let start = text.index(match.lowerBound, offsetBy: -60, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(start, offsetBy: maximumLength, limitedBy: text.endIndex) ?? text.endIndex
        return "\(start == text.startIndex ? "" : "…")\(text[start ..< end])\(end == text.endIndex ? "" : "…")"
    }

    private nonisolated static func searchPlaceholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ",")
    }

    private nonisolated static func requireReadySearchIndex(in db: Database) throws {
        let phase = try String.fetchOne(db, sql: "SELECT phase FROM search_index_state WHERE indexKind = 'fts'")
        guard phase == "ready" else { throw MeetingSearchError.indexUnavailable }
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
                try requireReadySearchIndex(in: db)
                return try searchProjectIDs(vaultID: vaultID, query: query, limit: limit, in: db)
            }
        }
    }

    private nonisolated static func searchProjectIDs(
        vaultID: UUID,
        query: String,
        limit: Int,
        in db: Database
    ) throws -> [UUID] {
        let tokens = try SearchFTS5Tokenizer.queryTokens(for: query, in: db)
        guard !tokens.isEmpty else { return [] }
        let tokenQuery = tokens.enumerated().map { ordinal, token in
            SearchFTS5Tokenizer.quotedQueryToken(token, isPrefix: ordinal == tokens.count - 1)
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

private struct FTSQueryToken {
    let ordinal: Int
    let token: String
    let query: String
    let estimatedDocuments: Int
}

private struct SearchHit {
    let relevance: Double
    let meetingDate: Date
}

private struct RankedMeeting {
    let meetingID: UUID
    let relevance: Double
    let meetingDate: Date
}

private extension MeetingSearchPage {
    static func empty(replacesResults: Bool) -> Self {
        Self(items: [], groups: [], hasMore: false, nextCursor: nil, replacesResults: replacesResults)
    }
}

enum MeetingSearchError: LocalizedError {
    case indexUnavailable
    case queryTooBroad

    var errorDescription: String? {
        switch self {
        case .indexUnavailable: L10n.searchUnavailable
        case .queryTooBroad: L10n.searchQueryTooBroad
        }
    }
}
