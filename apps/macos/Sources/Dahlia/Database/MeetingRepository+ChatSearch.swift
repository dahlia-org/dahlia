import DahliaMeetingAccess
import DahliaRuntimeSupport
import Foundation
import GRDB

extension MeetingRepository {
    nonisolated static func searchChatPage(
        workspaceID: UUID,
        accountID: String,
        criteria: MeetingSearchCriteria,
        offset: Int = 0,
        limit: Int = 25,
        dbQueue: DatabaseQueue
    ) async throws -> (threads: [CodexChatThreadSummary], hasMore: Bool) {
        try await withSearchDeadline {
            try await dbQueue.read { db in
                guard criteria.tagIDs.isEmpty, !criteria.pendingOnly else { return ([], false) }
                var conditions = ["t.workspaceID = ?", "t.accountID = ?"]
                var arguments: StatementArguments = [workspaceID, accountID]
                var source = "chat_threads t"
                var prefix = ""
                var prefixArguments = StatementArguments()
                if !criteria.text.isEmpty {
                    guard try String.fetchOne(db, sql: "SELECT phase FROM search_index_state WHERE indexKind = 'fts'") == "ready" else {
                        throw MeetingSearchError.indexUnavailable
                    }
                    let tokens = try SearchFTS5Tokenizer.queryTokens(for: criteria.text, in: db)
                    guard !tokens.isEmpty else { return ([], false) }
                    let ordered = try orderedQueryTokens(tokens, in: db)
                    guard let seed = ordered.first, seed.estimatedDocuments > 0 else { return ([], false) }
                    let terms = ordered.map { "{title description} : " + $0.query }
                    let requirements = terms.dropFirst().map { _ in
                        """
                        EXISTS (SELECT 1 FROM search_documents d CROSS JOIN search_documents_fts
                            WHERE d.kind = 'chat' AND d.chatThreadID = seeds.chatThreadID
                                AND search_documents_fts.rowid = d.id AND search_documents_fts MATCH ?)
                        """
                    }.joined(separator: " AND ")
                    // Start with the rarest token; check other words only in candidate Threads.
                    // CROSS JOIN keeps these rowid FTS probes from scanning global postings.
                    prefix = """
                    WITH seeds AS MATERIALIZED (
                        SELECT d.chatThreadID FROM search_documents_fts
                        CROSS JOIN search_documents d CROSS JOIN chat_threads scope
                        WHERE search_documents_fts MATCH ? AND d.id = search_documents_fts.rowid
                            AND d.kind = 'chat' AND scope.id = d.chatThreadID
                            AND scope.workspaceID = ? AND scope.accountID = ?
                        GROUP BY d.chatThreadID
                    ), candidates AS MATERIALIZED (
                        SELECT seeds.chatThreadID FROM seeds
                        \(requirements.isEmpty ? "" : "WHERE " + requirements)
                    ), hits AS MATERIALIZED (
                        SELECT d.chatThreadID, bm25(search_documents_fts) AS score
                        FROM candidates CROSS JOIN search_documents d CROSS JOIN search_documents_fts
                        WHERE d.kind = 'chat' AND d.chatThreadID = candidates.chatThreadID
                            AND search_documents_fts.rowid = d.id AND search_documents_fts MATCH ?
                    ), matches AS (
                        SELECT chatThreadID, MIN(score) AS score FROM hits GROUP BY chatThreadID
                    )
                    """
                    prefixArguments += [terms[0], workspaceID, accountID]
                    prefixArguments += StatementArguments(terms.dropFirst())
                    prefixArguments += [terms.joined(separator: " OR ")]
                    source = "matches CROSS JOIN chat_threads t"
                    conditions.append("t.id = matches.chatThreadID")
                }
                if !criteria.projectIDs.isEmpty {
                    let projects = try ProjectRecord.fetchResolvedAll(workspaceId: workspaceID, in: db)
                    let ids = Set(criteria.projectIDs.flatMap { ProjectRecord.hierarchy(projectId: $0, records: projects).map(\.id) })
                    guard !ids.isEmpty else { return ([], false) }
                    conditions.append("t.projectID IN (\(Array(repeating: "?", count: ids.count).joined(separator: ",")))")
                    arguments += StatementArguments(ids)
                }
                if let date = criteria.startDate { conditions.append("t.updatedAt >= ?")
                    arguments += [date]
                }
                if let date = criteria.endDate { conditions.append("t.updatedAt < ?")
                    arguments += [date]
                }
                arguments += [limit + 1, max(0, offset)]
                prefixArguments += arguments
                let rows = try ChatThreadRecord.fetchAll(db, sql: """
                \(prefix)
                SELECT t.* FROM \(source) WHERE \(conditions.joined(separator: " AND "))
                ORDER BY \(criteria.text.isEmpty ? "" : "matches.score,") t.updatedAt DESC, t.id DESC LIMIT ? OFFSET ?
                """, arguments: prefixArguments)
                return (
                    rows.prefix(limit).map { CodexChatThreadSummary(id: $0.id, title: $0.title, updatedAt: $0.updatedAt) },
                    rows.count > limit
                )
            }
        }
    }
}

func indexChatDocument(id: UUID, generation: Int, in db: Database) throws {
    guard let thread = try ChatThreadRecord.fetchOne(db, key: id.uuidString.lowercased()) else { return }
    try upsertChatDocument(sourceID: id, thread: thread, title: thread.title, body: "", generation: generation, in: db)
}

func indexChatItemDocument(id: UUID, generation: Int, in db: Database) throws {
    guard let item = try ChatItemRecord.fetchOne(db, key: id),
          let thread = try ChatThreadRecord.fetchOne(db, key: item.threadID),
          let message = try JSONDecoder().decode(JSONValue.self, from: Data(item.data.utf8)).objectValue,
          message["type"]?.stringValue == "message",
          ["user", "assistant"].contains(message["role"]?.stringValue ?? "") else { return }
    let body = CodexChatPromptCodec.decodeTextBlocks([message["content"]?.stringValue ?? ""]).text
    try upsertChatDocument(sourceID: id, thread: thread, title: "", body: body, generation: generation, in: db)
}

private func upsertChatDocument(sourceID: UUID, thread: ChatThreadRecord, title: String, body: String, generation: Int, in db: Database) throws {
    try upsertDocument(SearchDocumentProjection(
        kind: "chat", sourceID: sourceID, workspaceID: thread.workspaceID, meetingID: nil, projectID: thread.projectID,
        fields: SearchDocumentFields(title: title, description: body, calendar: "", tags: "", projectPath: "")
    ), generation: generation, in: db)
    try db.execute(
        sql: "UPDATE search_documents SET chatThreadID = ? WHERE kind = 'chat' AND sourceId = ?",
        arguments: [thread.id, sourceID]
    )
}
