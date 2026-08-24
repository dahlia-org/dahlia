import DahliaMeetingAccess
import Foundation
import GRDB
import OSLog

private let hybridSearchLogger = Logger(subsystem: "com.dahlia", category: "HybridSearch")

extension MeetingRepository {
    nonisolated static func searchMeetingSidebarPage(
        vaultId: UUID,
        query: String,
        mode: SearchMode = .advanced,
        queryEmbedding: [Float]? = nil,
        after cursor: MeetingSearchCursor? = nil,
        limit: Int,
        dbQueue: DatabaseQueue
    ) async throws -> MeetingSearchPage {
        try await searchMeetingSidebarPage(
            vaultId: vaultId,
            criteria: MeetingSearchCriteria(text: query),
            mode: mode,
            queryEmbedding: queryEmbedding,
            after: cursor,
            limit: limit,
            dbQueue: dbQueue
        )
    }

    nonisolated static func searchMeetingSidebarPage(
        vaultId: UUID,
        criteria: MeetingSearchCriteria,
        mode: SearchMode = .advanced,
        queryEmbedding: [Float]? = nil,
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
                return switch mode {
                case .simple:
                    try simpleSearch(
                        vaultId: vaultId,
                        criteria: criteria,
                        cursor: cursor,
                        limit: limit,
                        in: db
                    )
                case .advanced:
                    try fullTextSearch(
                        vaultId: vaultId,
                        criteria: criteria,
                        cursor: cursor,
                        limit: limit,
                        in: db
                    )
                case .neural:
                    if let queryEmbedding {
                        try hybridSearch(
                            vaultId: vaultId,
                            criteria: criteria,
                            queryEmbedding: queryEmbedding,
                            cursor: cursor,
                            limit: limit,
                            in: db
                        )
                    } else {
                        try fullTextSearch(
                            vaultId: vaultId,
                            criteria: criteria,
                            cursor: cursor,
                            limit: limit,
                            in: db
                        )
                    }
                }
            }
        }
    }

    private nonisolated static func hybridSearch(
        vaultId: UUID,
        criteria: MeetingSearchCriteria,
        queryEmbedding: [Float],
        cursor: MeetingSearchCursor?,
        limit: Int,
        in db: Database
    ) throws -> MeetingSearchPage {
        let vectorState = try Row.fetchOne(
            db,
            sql: """
            SELECT indexRevision, indexGeneration, phase, isEnabled, analyzerConfigurationHash
            FROM search_index_state WHERE indexKind = 'vector'
            """
        )
        let vectorIsEnabled = vectorState?["isEnabled"] as Bool? == true
        let vectorPhase = vectorState?["phase"] as String? ?? "missing"
        let configurationHashMatches = vectorState?["analyzerConfigurationHash"] as String?
            == EmbeddingGemmaDescriptor.configurationHash
        guard vectorIsEnabled, vectorPhase == "ready", configurationHashMatches else {
            hybridSearchLogger.notice("""
            Falling back to full-text search: enabled=\(vectorIsEnabled) phase=\(vectorPhase, privacy: .public) \
            configurationHashMatches=\(configurationHashMatches)
            """)
            return try fullTextSearch(
                vaultId: vaultId,
                criteria: criteria,
                cursor: cursor,
                limit: limit,
                in: db
            )
        }
        let ftsPage = try fullTextSearch(
            vaultId: vaultId,
            criteria: criteria,
            cursor: nil,
            limit: HybridSearchRRF.candidateLimit,
            in: db
        )
        let ftsRevision = try Int.fetchOne(
            db,
            sql: "SELECT indexRevision FROM search_index_state WHERE indexKind = 'fts'"
        ) ?? 0
        let vectorRevision: Int = vectorState?["indexRevision"] ?? 0
        let vectorGeneration: Int = vectorState?["indexGeneration"] ?? 1
        let offset: Int
        let replacesResults: Bool
        if case let .hybrid(oldFTS, oldVector, oldOffset) = cursor,
           oldFTS == ftsRevision, oldVector == vectorRevision {
            offset = oldOffset
            replacesResults = false
        } else {
            offset = 0
            replacesResults = cursor != nil
        }

        let vectorCandidates = try vectorSearchCandidates(
            vaultId: vaultId,
            criteria: criteria,
            queryEmbedding: queryEmbedding,
            indexGeneration: vectorGeneration,
            in: db
        )

        let ordered = HybridSearchRRF.rank(
            fullText: ftsPage.items.map(\.id),
            vector: vectorCandidates
        )
        let window = Array(ordered.dropFirst(offset).prefix(limit + 1))
        let visibleIDs = Array(window.prefix(limit))
        var itemsByID = Dictionary(uniqueKeysWithValues: ftsPage.items.map { ($0.id, $0) })
        let missing = visibleIDs.filter { itemsByID[$0] == nil }
        hybridSearchLogger.info("""
        Hybrid fusion: fullText=\(ftsPage.items.count) vectorCandidates=\(vectorCandidates.count) \
        vectorOnlyVisible=\(missing.count)
        """)
        for var item in try fetchMeetingSidebarItems(ids: missing, vaultId: vaultId, in: db) {
            item.searchMatchContext = .init(kind: .semantic, text: "")
            itemsByID[item.id] = item
        }
        let vectorIDs = Set(vectorCandidates)
        let items = visibleIDs.compactMap { itemsByID[$0] }.map { item in
            var item = item
            item.isSemanticHit = vectorIDs.contains(item.id)
            return item
        }
        let hasMore = window.count > limit
        return MeetingSearchPage(
            items: items,
            groups: MeetingDateGrouping.searchResultGroups(from: items),
            hasMore: hasMore,
            nextCursor: hasMore ? .hybrid(
                ftsRevision: ftsRevision,
                vectorRevision: vectorRevision,
                offset: offset + visibleIDs.count
            ) : nil,
            replacesResults: replacesResults
        )
    }

    /// Returns filtered meeting IDs above the similarity threshold, best first, capped at the RRF candidate limit.
    private nonisolated static func vectorSearchCandidates(
        vaultId: UUID,
        criteria: MeetingSearchCriteria,
        queryEmbedding: [Float],
        indexGeneration: Int,
        in db: Database
    ) throws -> [UUID] {
        let projects = try ProjectRecord.fetchResolvedAll(vaultId: vaultId, in: db)
        let includedProjects = descendantProjectIDs(selectedIDs: criteria.projectIDs, projects: projects)
        let filters = searchFilters(criteria: criteria, includedProjectIDs: includedProjects)
        var arguments: StatementArguments = [vaultId, indexGeneration]
        arguments += filters.arguments
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT search_documents.meetingId AS meetingId, search_documents_vec.embedding AS embedding,
                   meetings.projectId AS projectId, \(sidebarRecordingStartedAtSQL) AS meetingDate
            FROM search_documents_vec
            JOIN search_documents ON search_documents.id = search_documents_vec.documentId
            JOIN meetings ON meetings.id = search_documents.meetingId
            WHERE search_documents.kind = 'meeting' AND search_documents.vaultId = ?
              AND search_documents_vec.indexGeneration = ?
              AND search_documents_vec.sourceContentHash = search_documents.sourceContentHash
              \(filters.condition)
            """,
            arguments: arguments
        )
        var vectorHits: [(meetingID: UUID, similarity: Float, meetingDate: Date, projectID: UUID?)] = []
        vectorHits.reserveCapacity(rows.count)
        var maximumSimilarity: Float = -1
        for (index, row) in rows.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            let data: Data = row["embedding"]
            let vector = try EmbeddingVector.decode(data)
            let similarity = try EmbeddingVector.cosineSimilarity(queryEmbedding, vector)
            maximumSimilarity = max(maximumSimilarity, similarity)
            guard similarity >= HybridSearchRRF.minimumVectorSimilarity else { continue }
            vectorHits.append((
                row["meetingId"],
                similarity,
                row["meetingDate"],
                row["projectId"]
            ))
        }
        let projectIDs = Array(Set(vectorHits.compactMap(\.projectID)))
        var projectSimilarities: [UUID: Float] = [:]
        for start in stride(from: 0, to: projectIDs.count, by: 200) {
            let batch = Array(projectIDs[start ..< min(start + 200, projectIDs.count)])
            let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ",")
            var projectArguments: StatementArguments = [vaultId, indexGeneration]
            projectArguments += StatementArguments(batch)
            let projectRows = try Row.fetchAll(
                db,
                sql: """
                SELECT search_documents.projectId AS projectId, search_documents_vec.embedding AS embedding
                FROM search_documents_vec
                JOIN search_documents ON search_documents.id = search_documents_vec.documentId
                WHERE search_documents.kind = 'project' AND search_documents.vaultId = ?
                  AND search_documents_vec.indexGeneration = ?
                  AND search_documents_vec.sourceContentHash = search_documents.sourceContentHash
                  AND search_documents.projectId IN (\(placeholders))
                """,
                arguments: projectArguments
            )
            for row in projectRows {
                let projectID: UUID = row["projectId"]
                let data: Data = row["embedding"]
                projectSimilarities[projectID] = try EmbeddingVector.cosineSimilarity(
                    queryEmbedding,
                    EmbeddingVector.decode(data)
                )
            }
            try Task.checkCancellation()
        }
        for index in vectorHits.indices {
            guard let projectID = vectorHits[index].projectID,
                  let projectSimilarity = projectSimilarities[projectID],
                  projectSimilarity > vectorHits[index].similarity else { continue }
            vectorHits[index].similarity += HybridSearchRRF.projectContextRerankWeight
                * (projectSimilarity - vectorHits[index].similarity)
        }
        try Task.checkCancellation()
        vectorHits.sort {
            if $0.similarity != $1.similarity { return $0.similarity > $1.similarity }
            if $0.meetingDate != $1.meetingDate { return $0.meetingDate > $1.meetingDate }
            return $0.meetingID.uuidString < $1.meetingID.uuidString
        }
        hybridSearchLogger.info("""
        Vector scan: scannedEmbeddings=\(rows.count) aboveThreshold=\(vectorHits.count) \
        maxSimilarity=\(maximumSimilarity)
        """)
        return vectorHits.prefix(HybridSearchRRF.candidateLimit).map(\.meetingID)
    }

    /// Both callers wrap GRDB async reads, whose task cancellation interrupts the active SQLite statement.
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

    private nonisolated static let simpleProjectPathsCTE = """
    WITH RECURSIVE project_paths(id, vaultId, path) AS (
        SELECT id, vaultId, name
        FROM projects
        WHERE parentProjectId IS NULL AND vaultId = ?
        UNION ALL
        SELECT child.id, child.vaultId, project_paths.path || '/' || child.name
        FROM projects AS child
        JOIN project_paths ON project_paths.id = child.parentProjectId
        WHERE child.vaultId = ?
    )
    """

    private nonisolated static func simpleSearch(
        vaultId: UUID,
        criteria: MeetingSearchCriteria,
        cursor: MeetingSearchCursor?,
        limit: Int,
        in db: Database
    ) throws -> MeetingSearchPage {
        try requireReadySearchIndex(in: db)
        let chronologicalCursor: MeetingSidebarCursor? = if case let .chronological(value) = cursor { value } else {
            nil
        }
        let projects = try ProjectRecord.fetchResolvedAll(vaultId: vaultId, in: db)
        let includedProjects = descendantProjectIDs(selectedIDs: criteria.projectIDs, projects: projects)
        let filters = searchFilters(criteria: criteria, includedProjectIDs: includedProjects)
        let cursorFilter = sidebarCursorFilter(chronologicalCursor)
        let pattern = "%\(escapedLikePattern(criteria.text))%"
        var arguments: StatementArguments = [vaultId, vaultId, vaultId]
        arguments += filters.arguments
        for _ in 0 ..< 6 {
            arguments += [pattern]
        }
        arguments += cursorFilter.arguments
        arguments += [limit + 1]
        var ids = try UUID.fetchAll(
            db,
            sql: """
            \(simpleProjectPathsCTE)
            SELECT meetings.id
            FROM meetings
            LEFT JOIN calendar_events
              ON calendar_events.ical_uid = meetings.calendar_event_ical_uid
             AND calendar_events.recurrence_id = meetings.calendar_event_recurrence_id
            LEFT JOIN project_paths ON project_paths.id = meetings.projectId
            WHERE meetings.vaultId = ?
              \(filters.condition)
              AND (
                meetings.name LIKE ? ESCAPE '\\' COLLATE NOCASE
                OR meetings.description LIKE ? ESCAPE '\\' COLLATE NOCASE
                OR calendar_events.title LIKE ? ESCAPE '\\' COLLATE NOCASE
                OR calendar_events.description LIKE ? ESCAPE '\\' COLLATE NOCASE
                OR EXISTS (
                    SELECT 1 FROM meeting_tags
                    JOIN tags ON tags.id = meeting_tags.tagId
                    WHERE meeting_tags.meetingId = meetings.id
                      AND tags.name LIKE ? ESCAPE '\\' COLLATE NOCASE
                )
                OR project_paths.path LIKE ? ESCAPE '\\' COLLATE NOCASE
              )
              \(cursorFilter.condition)
            ORDER BY \(sidebarRecordingStartedAtSQL) DESC, meetings.id DESC
            LIMIT ?
            """,
            arguments: arguments
        )
        let hasMore = ids.count > limit
        if hasMore { ids.removeLast() }
        var itemsByID = try Dictionary(
            uniqueKeysWithValues: fetchMeetingSidebarItems(ids: ids, vaultId: vaultId, in: db)
                .map { ($0.id, $0) }
        )
        for id in ids {
            itemsByID[id]?.searchMatchContext = try simpleMatchContext(
                query: criteria.text,
                meetingID: id,
                projects: projects,
                in: db
            )
        }
        let items = ids.compactMap { itemsByID[$0] }
        return MeetingSearchPage(
            items: items,
            groups: MeetingDateGrouping.searchResultGroups(from: items),
            hasMore: hasMore,
            nextCursor: hasMore ? items.last.map { .chronological(MeetingSidebarCursor(item: $0)) } : nil,
            replacesResults: cursor != nil && chronologicalCursor == nil
        )
    }

    private nonisolated static func simpleMatchContext(
        query: String,
        meetingID: UUID,
        projects: [ProjectRecord],
        in db: Database
    ) throws -> MeetingSearchMatchContext {
        let meeting = try Row.fetchOne(
            db,
            sql: """
            SELECT meetings.name, meetings.description, meetings.projectId,
                   calendar_events.title AS calendarTitle,
                   calendar_events.description AS calendarDescription
            FROM meetings LEFT JOIN calendar_events
              ON calendar_events.ical_uid = meetings.calendar_event_ical_uid
             AND calendar_events.recurrence_id = meetings.calendar_event_recurrence_id
            WHERE meetings.id = ?
            """,
            arguments: [meetingID]
        )
        let title: String = meeting?["name"] ?? ""
        if title.localizedStandardContains(query) {
            return .init(kind: .title, text: title)
        }
        let tags = try Row.fetchAll(
            db,
            sql: """
            SELECT tags.name, tags.colorHex FROM tags
            JOIN meeting_tags ON meeting_tags.tagId = tags.id
            WHERE meeting_tags.meetingId = ? ORDER BY tags.id
            """,
            arguments: [meetingID]
        )
        if let tag = tags.first(where: { ($0["name"] as String).localizedStandardContains(query) }) {
            return .init(kind: .tag, text: tag["name"], colorHex: tag["colorHex"])
        }
        let projectID: UUID? = meeting?["projectId"]
        if let path = projectID.flatMap({ id in projects.first { $0.id == id }?.path }),
           path.localizedStandardContains(query) {
            return .init(kind: .project, text: path)
        }
        let calendar = [meeting?["calendarTitle"] as String?, meeting?["calendarDescription"] as String?]
            .compactMap(\.self)
            .joined(separator: " ")
        if calendar.localizedStandardContains(query) {
            return .init(kind: .calendar, text: calendar)
        }
        let description: String = meeting?["description"] ?? ""
        return .init(kind: .description, text: snippet(description, matching: query))
    }

    private nonisolated static func fullTextSearch(
        vaultId: UUID,
        criteria: MeetingSearchCriteria,
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
                            SELECT id, meetingId
                            FROM search_documents
                            WHERE kind = 'meeting'
                              AND meetingId IN (\(searchPlaceholders(ids.count)))
                        )
                        SELECT candidate_documents.meetingId AS meetingId,
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
                        field: field,
                        ordinal: queryToken.ordinal,
                        token: queryToken.token,
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

    private nonisolated static func merge(
        rows: [Row],
        field: SearchField,
        ordinal: Int,
        token: String,
        into meetingHits: inout [UUID: [Int: SearchTokenHit]]
    ) {
        for row in rows {
            let meetingID: UUID = row["meetingId"]
            let hit = SearchTokenHit(
                field: field,
                token: token,
                relevance: row["relevance"],
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
                matchClass: evidence.field.matchClass,
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
            return try .init(
                kind: .description,
                text: snippet(meetingText("description", meetingID: meetingID, in: db), matching: hit.token)
            )
        case .summary:
            return try .init(
                kind: .summary,
                text: snippet(summaryBodyText(meetingID: meetingID, in: db), matching: hit.token)
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
                return name.localizedStandardContains(hit.token)
            }) ?? tags.first
            return .init(kind: .tag, text: tag?["name"] ?? "", colorHex: tag?["colorHex"])
        case .projectPath:
            let projectID = try UUID.fetchOne(db, sql: "SELECT projectId FROM meetings WHERE id = ?", arguments: [meetingID])
            return .init(kind: .project, text: projectID.flatMap { id in projects.first { $0.id == id }?.path } ?? "")
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

    nonisolated static func snippet(_ text: String, matching token: String) -> String {
        guard let match = text.range(
            of: token,
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: .current
        ) else { return String(text.prefix(180)) }
        return snippet(text, around: match)
    }

    nonisolated static func snippet(_ text: String, around match: Range<String.Index>) -> String {
        let maximumLength = 180
        guard text.count > maximumLength else { return text }
        let start = text.index(match.lowerBound, offsetBy: -60, limitedBy: text.startIndex) ?? text.startIndex
        let hasLeadingEllipsis = start != text.startIndex
        let availableLength = maximumLength - (hasLeadingEllipsis ? 1 : 0)
        let availableEnd = text.index(start, offsetBy: availableLength, limitedBy: text.endIndex) ?? text.endIndex
        let hasTrailingEllipsis = availableEnd != text.endIndex
        let contentLength = availableLength - (hasTrailingEllipsis ? 1 : 0)
        let end = text.index(start, offsetBy: contentLength, limitedBy: text.endIndex) ?? text.endIndex
        return "\(hasLeadingEllipsis ? "…" : "")\(text[start ..< end])\(hasTrailingEllipsis ? "…" : "")"
    }

    private nonisolated static func searchPlaceholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ",")
    }

    private nonisolated static func escapedLikePattern(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private nonisolated static func requireReadySearchIndex(in db: Database) throws {
        let phase = try String.fetchOne(db, sql: "SELECT phase FROM search_index_state WHERE indexKind = 'fts'")
        guard phase == "ready" else { throw MeetingSearchError.indexUnavailable }
    }

}

enum HybridSearchRRF {
    static let candidateLimit = 100
    static let minimumVectorSimilarity: Float = 0.45
    static let projectContextRerankWeight: Float = 0.2

    static func rank(fullText: [UUID], vector: [UUID], rankConstant: Int = 60) -> [UUID] {
        var scores: [UUID: Double] = [:]
        let fullTextRanks = Dictionary(uniqueKeysWithValues: fullText.enumerated().map { ($1, $0) })
        let vectorRanks = Dictionary(uniqueKeysWithValues: vector.enumerated().map { ($1, $0) })
        for (rank, id) in fullText.enumerated() {
            scores[id, default: 0] += 1 / Double(rankConstant + rank + 1)
        }
        for (rank, id) in vector.enumerated() {
            scores[id, default: 0] += 1 / Double(rankConstant + rank + 1)
        }
        return scores.sorted {
            if $0.value != $1.value { return $0.value > $1.value }
            let lhsFullTextRank = fullTextRanks[$0.key]
            let rhsFullTextRank = fullTextRanks[$1.key]
            if (lhsFullTextRank != nil) != (rhsFullTextRank != nil) { return lhsFullTextRank != nil }
            if lhsFullTextRank != rhsFullTextRank {
                return (lhsFullTextRank ?? .max) < (rhsFullTextRank ?? .max)
            }
            let lhsVectorRank = vectorRanks[$0.key]
            let rhsVectorRank = vectorRanks[$1.key]
            if lhsVectorRank != rhsVectorRank { return (lhsVectorRank ?? .max) < (rhsVectorRank ?? .max) }
            return $0.key.uuidString < $1.key.uuidString
        }.map(\.key)
    }
}

extension MeetingRepository {
    nonisolated static func searchProjectIDs(
        vaultID: UUID,
        query: String,
        mode: SearchMode = .advanced,
        queryEmbedding: [Float]? = nil,
        limit: Int,
        dbQueue: DatabaseQueue
    ) async throws -> [UUID] {
        try await withSearchDeadline {
            try await dbQueue.read { db in
                try requireReadySearchIndex(in: db)
                return switch mode {
                case .simple:
                    try simpleProjectIDs(vaultID: vaultID, query: query, limit: limit, in: db)
                case .advanced:
                    try searchProjectIDs(vaultID: vaultID, query: query, limit: limit, in: db)
                case .neural:
                    if let queryEmbedding {
                        try hybridProjectIDs(
                            vaultID: vaultID,
                            query: query,
                            queryEmbedding: queryEmbedding,
                            limit: limit,
                            in: db
                        )
                    } else {
                        try searchProjectIDs(vaultID: vaultID, query: query, limit: limit, in: db)
                    }
                }
            }
        }
    }

    private nonisolated static func hybridProjectIDs(
        vaultID: UUID,
        query: String,
        queryEmbedding: [Float],
        limit: Int,
        in db: Database
    ) throws -> [UUID] {
        guard let state = try Row.fetchOne(
            db,
            sql: """
            SELECT phase, indexGeneration, isEnabled, analyzerConfigurationHash
            FROM search_index_state WHERE indexKind = 'vector'
            """
        ), state["isEnabled"] as Bool, state["phase"] as String == "ready",
        state["analyzerConfigurationHash"] as String == EmbeddingGemmaDescriptor.configurationHash else {
            return try searchProjectIDs(vaultID: vaultID, query: query, limit: limit, in: db)
        }
        let fullText = try searchProjectIDs(
            vaultID: vaultID,
            query: query,
            limit: HybridSearchRRF.candidateLimit,
            in: db
        )
        let generation: Int = state["indexGeneration"]
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT search_documents.projectId AS projectId, search_documents_vec.embedding AS embedding
            FROM search_documents_vec
            JOIN search_documents ON search_documents.id = search_documents_vec.documentId
            WHERE search_documents.kind = 'project' AND search_documents.vaultId = ?
              AND search_documents_vec.indexGeneration = ?
              AND search_documents_vec.sourceContentHash = search_documents.sourceContentHash
            """,
            arguments: [vaultID, generation]
        )
        var vectorHits: [(UUID, Float)] = []
        vectorHits.reserveCapacity(rows.count)
        for (index, row) in rows.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            let data: Data = row["embedding"]
            let score = try EmbeddingVector.cosineSimilarity(
                queryEmbedding,
                EmbeddingVector.decode(data)
            )
            guard score >= HybridSearchRRF.minimumVectorSimilarity else { continue }
            vectorHits.append((row["projectId"], score))
        }
        try Task.checkCancellation()
        vectorHits.sort {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            return $0.0.uuidString < $1.0.uuidString
        }
        let vector = vectorHits.prefix(HybridSearchRRF.candidateLimit).map(\.0)
        return Array(HybridSearchRRF.rank(fullText: fullText, vector: vector).prefix(limit))
    }

    private nonisolated static func simpleProjectIDs(
        vaultID: UUID,
        query: String,
        limit: Int,
        in db: Database
    ) throws -> [UUID] {
        let pattern = "%\(escapedLikePattern(query))%"
        return try UUID.fetchAll(
            db,
            sql: """
            \(simpleProjectPathsCTE)
            SELECT projects.id FROM projects
            JOIN project_paths ON project_paths.id = projects.id
            WHERE projects.vaultId = ? AND (
                projects.name LIKE ? ESCAPE '\\' COLLATE NOCASE
                OR projects.description LIKE ? ESCAPE '\\' COLLATE NOCASE
                OR project_paths.path LIKE ? ESCAPE '\\' COLLATE NOCASE
            )
            ORDER BY project_paths.path, projects.id
            LIMIT ?
            """,
            arguments: [vaultID, vaultID, vaultID, pattern, pattern, pattern, limit]
        )
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

private enum SearchField: String, CaseIterable {
    case title, tags, projectPath, calendar, description, summary

    var matchClass: Int {
        switch self {
        case .title: 0
        case .tags, .projectPath, .calendar: 1
        case .description, .summary: 2
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
    let field: SearchField
    let token: String
    let relevance: Double
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
