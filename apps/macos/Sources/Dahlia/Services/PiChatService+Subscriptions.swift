import Foundation
import GRDB

extension PiChatService {
    func relatedThreads(parentThreadID: String) async throws -> [CodexChatThreadSummary] {
        let provider = try await runtime.currentProvider()
        let store = try history()
        _ = try store.thread(id: parentThreadID, accountID: provider.accountKey)
        return try await store.dbQueue.read { db in
            try ChatThreadRecord.fetchAll(db, sql: """
            SELECT * FROM chat_threads WHERE accountID = ? AND (parentThreadID = ? OR id IN (
                SELECT threadID FROM chat_runs WHERE requestedByThreadID = ?))
            ORDER BY updatedAt DESC LIMIT 100
            """, arguments: [provider.accountKey, parentThreadID, parentThreadID]).map { thread in
                let request = try ChatRunRecord.fetchOne(db, sql: """
                SELECT * FROM chat_runs WHERE threadID = ? AND requestedByThreadID = ?
                ORDER BY createdAt, id LIMIT 1
                """, arguments: [thread.id, parentThreadID])
                let source: Row? = if request?.requestedByRunID == nil {
                    try Row.fetchOne(db, sql: """
                    SELECT id, runID FROM chat_items WHERE threadID = ? AND createdAt <= ?
                    AND \(ChatItemRecord.messagePredicate()) ORDER BY seq DESC LIMIT 1
                    """, arguments: [parentThreadID, request?.createdAt ?? thread.createdAt])
                } else {
                    nil
                }
                let sourceRunID: UUID? = request?.requestedByRunID ?? source?["runID"]
                let requestMessageID = try UUID.fetchOne(db, sql: """
                SELECT id FROM chat_items WHERE threadID = ? AND runID = ?
                AND \(ChatItemRecord.messagePredicate()) ORDER BY seq LIMIT 1
                """, arguments: [parentThreadID, sourceRunID]) ?? source?["id"]
                let latestRun = try ChatRunRecord.fetchOne(
                    db, sql: "SELECT * FROM chat_runs WHERE threadID = ? ORDER BY createdAt DESC, id DESC LIMIT 1", arguments: [thread.id]
                )
                return try CodexChatThreadSummary(
                    id: thread.id,
                    title: thread.title,
                    updatedAt: thread.updatedAt,
                    parentThreadID: thread.parentThreadID,
                    status: latestRun?.status ?? thread.status,
                    firstMessage: ChatThreadStore.firstMessagePreview(threadID: thread.id, in: db),
                    model: thread.model,
                    requestMessageID: requestMessageID?.uuidString.lowercased(),
                    requestRunID: sourceRunID,
                    startedAt: latestRun?.startedAt,
                    completedAt: latestRun?.completedAt
                )
            }
        }
    }

    func observeThreads() async -> AsyncStream<[CodexChatRuntimeState]> {
        let id = UUID.v7()
        let (stream, reader) = AsyncStream<[CodexChatRuntimeState]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        stateReaders[id] = reader
        reader.yield(runtimeStates())
        reader.onTermination = { [weak self] _ in Task { await self?.removeStateReader(id) } }
        return stream
    }

    func removeStateReader(_ id: UUID) { stateReaders[id] = nil }

    func runtimeStates() -> [CodexChatRuntimeState] {
        var states = sessions.compactMap { id, session -> CodexChatRuntimeState? in
            guard let turn = session.turn else { return nil }
            return CodexChatRuntimeState(
                threadID: id,
                accountID: session.provider.accountKey,
                turnID: turn.id,
                approvals: Array(turn.broadcast.approvals.values).sorted { $0.id < $1.id },
                isScheduled: turn.run.origin == "schedule"
            )
        }
        let active = Set(states.map(\.threadID))
        let queued: [ChatRunRecord] = (try? history().dbQueue.read { db in
            try ChatRunRecord.fetchAll(db, sql: "SELECT * FROM chat_runs WHERE status = 'queued' ORDER BY createdAt LIMIT 100")
        }) ?? []
        var included = active
        for run in queued where !included.contains(run.threadID) {
            if let record = try? history().dbQueue.read({
                try ChatThreadRecord.fetchOne($0, key: run.threadID) }) {
                states.append(CodexChatRuntimeState(
                    threadID: run.threadID,
                    accountID: record.accountID,
                    turnID: run.id,
                    approvals: [],
                    status: "queued", isScheduled: run.origin == "schedule"
                ))
                included.insert(run.threadID)
            }
        }
        for (threadID, settled) in settledRuns where !included.contains(threadID) {
            states.append(CodexChatRuntimeState(
                threadID: threadID, accountID: settled.accountID, turnID: settled.runID, approvals: [], status: "settled",
                isScheduled: settled.isScheduled
            ))
        }
        return states
    }

    func publishStates() {
        let states = runtimeStates()
        for reader in stateReaders.values {
            reader.yield(states)
        }
    }

    func detachReader(threadID: String, runID: UUID, readerID: UUID) {
        guard sessions[threadID]?.turn?.id == runID else { return }
        sessions[threadID]?.turn?.broadcast.readers[readerID] = nil
    }

    /// History and the partial message are captured without an actor suspension, so no event falls between them.
    func attach(threadID: String) async throws -> CodexChatTurnHandle? {
        let provider = try await runtime.currentProvider()
        let store = try history()
        let record = try store.thread(id: threadID, accountID: provider.accountKey)
        guard var turn = sessions[threadID]?.turn else { return nil }
        let page = try store.messagePage(threadID: threadID)
        let parent = try store.parentSummary(for: record)
        let snapshot = CodexChatThread(
            id: record.id,
            title: record.title,
            messages: page.messages,
            model: record.model,
            reasoningEffort: record.reasoningEffort,
            approvalMethod: sessions[threadID]?.approvalMethod,
            earlierMessagesCursor: page.earlierCursor, isReadOnly: record.scheduleID != nil,
            parentThread: parent,
            lastItemSeq: page.lastItemSeq
        )
        let id = UUID.v7()
        let (stream, reader) = AsyncThrowingStream<CodexChatTurnEvent, any Error>.makeStream(bufferingPolicy: .bufferingOldest(256))
        reader.yield(.started(turnID: turn.wireID))
        if let itemID = turn.broadcast.itemID {
            if !turn.broadcast.reasoning.isEmpty { reader.yield(.reasoningDelta(itemID: itemID, summaryIndex: 0, text: turn.broadcast.reasoning)) }
            if !turn.broadcast.text.isEmpty { reader.yield(.delta(itemID: itemID, text: turn.broadcast.text)) }
        }
        if let activity = turn.broadcast.activity { reader.yield(.toolActivity(activity)) }
        for approval in turn.broadcast.approvals.values {
            reader.yield(.approvalRequested(approval))
        }
        turn.broadcast.readers[id] = reader
        sessions[threadID]?.turn = turn
        let runID = turn.id
        reader.onTermination = { [weak self] _ in Task { await self?.detachReader(threadID: threadID, runID: runID, readerID: id) } }
        return CodexChatTurnHandle(id: turn.id, events: stream, approvalMethod: sessions[threadID]?.approvalMethod, snapshot: snapshot)
    }

    func stopAccountRuns(except accountID: String) async {
        if let activeReview, activeReview.account != accountID { await runtime.close(activeReview.connection) }
        let persisted = (try? history().activeRunAccounts()) ?? []
        let accounts = Set(sessions.values.map(\.provider.accountKey) + persisted).subtracting([accountID])
        stoppingAccounts.formUnion(accounts)
        for account in accounts {
            try? history().suppressRunNotifications(accountID: account)
            try? history().interruptQueuedRuns(accountID: account, preservingSchedules: true)
        }
        publishStates()
        for (id, session) in sessions where session.provider.accountKey != accountID {
            await closeSession(id)
        }
        stoppingAccounts.subtract(accounts)
    }

    func chosenApprovalMethod(_ threadID: String) -> CodexChatApprovalMethod? {
        sessions[threadID]?.approvalMethod ?? chosenApprovalMethods[threadID]
    }

    /// What a tool call is judged by. The thread's method is never looser than the current choice of the thread that
    /// requested the running work, or of its parent, even when that choice changed after the run began.
    func effectiveApprovalMethod(_ threadID: String) -> CodexChatApprovalMethod {
        guard let session = sessions[threadID], var method = session.approvalMethod else { return .ask }
        let parent = (try? history().thread(id: threadID, accountID: session.provider.accountKey))?.parentThreadID
        for ceiling in [session.turn?.run.requestedByThreadID, parent].compactMap(\.self) {
            if let chosen = chosenApprovalMethod(ceiling) { method = Self.stricterApproval(method, chosen) }
        }
        return method
    }

    func inheritedApprovalMethod(threadID: String, requested: CodexChatApprovalMethod) throws -> CodexChatApprovalMethod {
        guard let provider = sessions[threadID]?.provider else { return requested }
        let record = try history().thread(id: threadID, accountID: provider.accountKey)
        guard let parent = record.parentThreadID else { return requested }
        let parentMethod = chosenApprovalMethod(parent) ?? .autoReview
        return Self.stricterApproval(requested, parentMethod)
    }

    nonisolated static func stricterApproval(_ left: CodexChatApprovalMethod, _ right: CodexChatApprovalMethod) -> CodexChatApprovalMethod {
        let order: [CodexChatApprovalMethod] = [.ask, .autoReview, .fullAccess]
        return order[min(order.firstIndex(of: left) ?? 0, order.firstIndex(of: right) ?? 0)]
    }
}
