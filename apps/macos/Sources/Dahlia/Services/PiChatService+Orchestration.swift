import DahliaRuntimeSupport
import Foundation
import GRDB

extension PiChatService {
    nonisolated static let readThreadTools = ["dahlia_thread_list", "dahlia_thread_search", "dahlia_thread_read"]
    nonisolated static let manageThreadTools = [
        "dahlia_thread_start",
        "dahlia_thread_send",
        "dahlia_thread_wait",
        "dahlia_thread_interrupt",
        "dahlia_thread_update",
    ]

    func runDidSettle(_ threadID: String, accountID: String? = nil) {
        guard let account = accountID ?? sessions[threadID]?.provider.accountKey else { return }
        Task {
            await scheduleRuns(accountID: account)
            await deliverResults(accountID: account)
        }
    }

    /// Three agent-originated runs per account; user-originated runs bypass this queue.
    func scheduleRuns(accountID: String) async {
        guard !schedulingAccounts.contains(accountID), !stoppingAccounts.contains(accountID) else { return }
        schedulingAccounts.insert(accountID)
        var canReschedule = false
        defer {
            schedulingAccounts.remove(accountID)
            let canStart = ((try? history().queuedRuns(accountID: accountID)) ?? []).contains {
                sessions[$0.threadID]?.turn == nil && startingTurns[$0.threadID] == nil
            }
            let active = sessions.values.filter { $0.provider.accountKey == accountID && $0.turn != nil && $0.turn?.run.rootRunID != $0.turn?.run.id }
                .count
            if canReschedule, canStart, active < 3, !stoppingAccounts.contains(accountID) {
                Task { await self.scheduleRuns(accountID: accountID) }
            }
        }
        do {
            let provider = try await runtime.currentProvider()
            guard provider.accountKey == accountID else {
                try history().interruptQueuedRuns(accountID: accountID)
                publishStates()
                return
            }
            canReschedule = true
            let queued = try history().queuedRuns(accountID: accountID)
            for run in queued {
                let active = sessions.filter { _, session in
                    session.provider.accountKey == accountID && session.turn?.run.rootRunID != session.turn?.run.id
                        && session.turn != nil
                }.count
                guard active < 3 else { break }
                guard sessions[run.threadID]?.turn == nil, startingTurns[run.threadID] == nil,
                      try history().run(id: run.id)?.status == "queued" else { continue }
                scheduledRuns[run.threadID] = run
                do {
                    _ = try await beginTurn(
                        threadID: run.threadID,
                        inputs: [.text(run.input)],
                        model: run.model,
                        effort: run.effort,
                        approvalMethod: CodexChatApprovalMethod(rawValue: run.approvalMethod) ?? .ask,
                        expectedProvider: provider
                    )
                } catch {
                    scheduledRuns[run.threadID] = nil
                    // A run that failed after its turn began has already ended; one that never started ends here.
                    if try history().run(id: run.id)?.status == "queued" {
                        endRun(run.id, threadID: run.threadID, accountID: accountID, status: "failed", savingThread: false)
                    }
                }
            }
        } catch {
            canReschedule = false
            ErrorReportingService.capture(error, context: ["source": "chatRunQueue"])
        }
    }

    func deliverResults(accountID: String) async {
        guard !stoppingAccounts.contains(accountID) else { return }
        do {
            guard try await runtime.currentProvider().accountKey == accountID else {
                // Runs that end after their account was switched away never restart a parent when the user returns.
                try history().suppressRunNotifications(accountID: accountID)
                return
            }
            let requesters = try await history().dbQueue.read { db in
                try String.fetchAll(db, sql: """
                SELECT DISTINCT r.requestedByThreadID FROM chat_runs r JOIN chat_threads t ON t.id = r.requestedByThreadID
                WHERE t.accountID = ? AND r.resultDeliveredAt IS NULL
                    AND r.status IN ('completed', 'interrupted', 'failed', 'waitingForUser')
                """, arguments: [accountID])
            }
            for requester in requesters {
                guard sessions[requester]?.turn == nil, startingTurns[requester] == nil, !waitingParents.contains(requester) else { continue }
                guard try !history().queuedRuns(accountID: accountID).contains(where: { $0.threadID == requester }) else { continue }
                let pending = try history().undeliveredRuns(requesterID: requester)
                let stopped = try pending.filter {
                    try $0.suppressAutomaticNotification || (history().run(id: $0.rootRunID)?.stoppedByUser == true)
                }
                try history().markRunsDelivered(stopped)
                let runs = pending.filter { run in !stopped.contains(where: { $0.id == run.id }) }
                guard let first = runs.first else { continue }
                let text = try notificationText(runs, accountID: accountID)
                let parent = try history().thread(id: requester, accountID: accountID)
                let id = UUID.v7()
                let run = try ChatRunRecord(
                    id: id,
                    threadID: requester,
                    rootRunID: first.rootRunID,
                    status: "queued",
                    input: text,
                    model: parent.model,
                    effort: parent.reasoningEffort ?? "medium",
                    approvalMethod: chosenApprovalMethod(requester)?.rawValue ?? CodexChatApprovalMethod.autoReview.rawValue,
                    createdAt: .now
                )
                try history().enqueueNotification(run, deliveredRuns: runs)
            }
            await scheduleRuns(accountID: accountID)
        } catch {
            ErrorReportingService.capture(error, context: ["source": "chatRunDelivery"])
        }
    }

    func notificationText(_ runs: [ChatRunRecord], accountID: String) throws -> String {
        let results = try runs.map { run -> JSONValue in
            let record = try history().thread(id: run.threadID, accountID: accountID)
            return .object([
                "run_id": .string(run.id.uuidString),
                "thread_id": .string(run.threadID),
                "title": .string(String(record.title.prefix(256))),
                "status": .string(run.status),
                "excerpt": .string(run.resultExcerpt),
                // The excerpt is a prefix; the full reply stays in the thread for `dahlia_thread_read`.
                "truncated": .bool(run.resultExcerpt.count >= ChatThreadStore.resultExcerptLimit),
            ])
        }
        let json = try String(decoding: JSONEncoder().encode(JSONValue.array(results)), as: UTF8.self)
        return "<thread_results source=\"dahlia\" untrusted=\"true\">\n\(json)\n</thread_results>"
    }

    func threadTool(_ method: String, payload: JSONValue, threadID: String, processID: UUID) async throws -> JSONValue {
        guard let callerSession = sessions[threadID], callerSession.processID == processID,
              let callerTurn = callerSession.turn else { throw CancellationError() }
        let store = try history()
        let account = callerSession.provider.accountKey
        let caller = try store.thread(id: threadID, accountID: account)
        guard try await runtime.currentProvider() == callerSession.provider,
              sessions[threadID]?.processID == processID,
              sessions[threadID]?.turn?.id == callerTurn.id else { throw CancellationError() }
        let args = payload.objectValue ?? [:]
        if let input = args["input"]?.stringValue, input.count > 32000 { throw PiRuntimeError.rpcError(
            code: nil,
            message: "Input exceeds 32000 characters"
        ) }
        if let key = args["client_request_id"]?.stringValue, key.count > 256 { throw PiRuntimeError.invalidProtocolResponse }
        let readOnly = ["thread_list", "thread_read", "thread_search"].contains(method)
        // Depth is a property of the run, not only of the thread: work done for another thread never delegates further.
        guard readOnly || (caller.parentThreadID == nil && callerTurn.run.requestedByThreadID == nil) else {
            throw PiRuntimeError.rpcError(code: nil, message: "Work requested by another thread has read-only thread tools")
        }
        if method == "thread_list" {
            return try store.toolThreadPage(accountID: account, arguments: args)
        }
        if method == "thread_search" {
            guard let query = args["query"]?.stringValue?.nilIfBlank else { throw PiRuntimeError.invalidProtocolResponse }
            let page = try await MeetingRepository.searchChatPage(
                accountID: account,
                criteria: .init(text: String(query.prefix(1024))),
                offset: 0,
                limit: 50,
                dbQueue: store.dbQueue
            )
            return .object([
                "threads": .array(page.threads.map { .object(["id": .string($0.id), "title": .string($0.title)]) }),
                "has_more": .bool(page.hasMore),
            ])
        }
        if method == "thread_start" {
            return try await startChildThread(arguments: args, caller: caller, callerSession: callerSession, callerTurn: callerTurn)
        }
        if method == "thread_wait" {
            return try await waitForThreads(arguments: args, threadID: threadID, processID: processID, callerTurn: callerTurn, account: account)
        }
        guard let targetID = args["thread_id"]?.stringValue else { throw PiRuntimeError.invalidProtocolResponse }
        let target = try store.thread(id: targetID, accountID: account)
        if method == "thread_read" { return try readThread(targetID, arguments: args, requesterID: threadID) }
        guard targetID != threadID else { throw PiRuntimeError.rpcError(code: nil, message: "Cannot manage your own thread") }
        switch method {
        case "thread_send":
            return try await sendToThread(targetID, arguments: args, caller: caller, callerTurn: callerTurn)
        case "thread_interrupt":
            return try await interruptThread(targetID, arguments: args, account: account)
        case "thread_update":
            guard let title = args["title"]?.stringValue?.nilIfBlank else { throw PiRuntimeError.invalidProtocolResponse }
            try await renameThread(threadID: targetID, name: String(title.prefix(256)))
            return .object(["thread_id": .string(target.id), "title": .string(String(title.prefix(256)))])
        default: throw PiRuntimeError.invalidProtocolResponse
        }
    }

    func readThread(_ targetID: String, arguments args: [String: JSONValue], requesterID: String) throws -> JSONValue {
        let store = try history()
        // Fetched before the read, so a run that settles during it is still announced.
        let settled = try store.undeliveredRuns(requesterID: requesterID).filter { $0.threadID == targetID && $0.status != "waitingForUser" }
        let page = try store.readForTool(threadID: targetID, arguments: args)
        // The requester has the result once it reads to the end; a second copy would only spend its run budget.
        if args["view"]?.stringValue != "activity", page.objectValue?["next_cursor"] == .null, page.objectValue?["complete"] == .bool(true) {
            try store.markRunsDelivered(settled)
        }
        return page
    }

    func sendToThread(
        _ targetID: String, arguments args: [String: JSONValue], caller: ChatThreadRecord, callerTurn: Turn
    ) async throws -> JSONValue {
        guard let input = args["input"]?.stringValue?.nilIfBlank,
              let requestID = args["client_request_id"]?.stringValue?.nilIfBlank else { throw PiRuntimeError.invalidProtocolResponse }
        let mode = args["mode"]?.stringValue ?? "auto"
        // A retry key names one delivery, queued or steered, so it is checked before anything reaches a thread.
        let steerKey = "\(caller.id)|\(callerTurn.run.rootRunID)|\(requestID)"
        let delivered = try history().requestedRun(requesterID: caller.id, rootRunID: callerTurn.run.rootRunID, clientRequestID: requestID)
        if let earlier = delivered ?? steeredRequests[steerKey] {
            guard earlier.threadID == targetID else {
                throw PiRuntimeError.rpcError(code: nil, message: "client_request_id was already used for another thread in this request")
            }
            return runJSON(earlier, delivery: "duplicate")
        }
        // Only the requester may add input to a run: a turn the user or another thread started is never redirected.
        let ownedTurn = sessions[targetID]?.turn.flatMap { $0.run.requestedByThreadID == caller.id ? $0 : nil }
        if mode == "steer" || (mode == "auto" && ownedTurn != nil) {
            guard let turn = ownedTurn else {
                throw PiRuntimeError.rpcError(code: nil, message: "Only a running run you requested can be steered; use queue")
            }
            steeredRequests[steerKey] = turn.run
            do {
                try await steer(threadID: targetID, turnID: turn.wireID, inputs: [.text(agentRequestText(input, callerID: caller.id))])
                return runJSON(turn.run, delivery: "steered")
            } catch {
                steeredRequests[steerKey] = nil
                // The run settled first; auto queues the input as the next run instead.
                guard mode == "auto", sessions[targetID]?.turn?.id != turn.id else { throw error }
            }
        }
        let run = try queueAgentRun(targetID: targetID, caller: caller, turn: callerTurn, input: input, requestID: requestID, arguments: args)
        // A retry returns its earlier run; the same key for another thread would silently drop this input.
        guard run.threadID == targetID else {
            throw PiRuntimeError.rpcError(code: nil, message: "client_request_id was already used for another thread in this request")
        }
        Task { await self.scheduleRuns(accountID: caller.accountID) }
        return runJSON(run, delivery: "queued")
    }

    func interruptThread(_ targetID: String, arguments args: [String: JSONValue], account: String) async throws -> JSONValue {
        let store = try history()
        if let raw = args["run_id"]?.stringValue {
            guard let id = UUID(uuidString: raw), try store.run(id: id)?.threadID == targetID else { throw PiRuntimeError.invalidProtocolResponse }
            if sessions[targetID]?.turn?.run.id == id { await abort(threadID: targetID) } else { try store.interruptQueuedRun(id) }
            publishStates()
            return .object(["thread_id": .string(targetID), "run_id": .string(raw), "stop_requested": .bool(true)])
        }
        try store.interruptQueuedRuns(accountID: account, threadID: targetID)
        publishStates()
        await abort(threadID: targetID)
        return .object(["thread_id": .string(targetID), "stop_requested": .bool(true)])
    }

    func startChildThread(
        arguments args: [String: JSONValue],
        caller: ChatThreadRecord,
        callerSession: Session,
        callerTurn: Turn
    ) async throws -> JSONValue {
        let store = try history()
        let threadID = caller.id
        let account = caller.accountID
        guard let input = args["input"]?.stringValue?.nilIfBlank,
              let requestID = args["client_request_id"]?.stringValue?.nilIfBlank else { throw PiRuntimeError.invalidProtocolResponse }
        let rootRunID = callerTurn.run.rootRunID
        if let existing = try store.requestedRun(requesterID: threadID, rootRunID: rootRunID, clientRequestID: requestID) { return runJSON(existing) }
        let context = try store.toolContext(arguments: args, accountID: account)
        let child = try await startThread(
            model: args["model"]?.stringValue ?? callerSession.model,
            effort: args["effort"]?.stringValue ?? caller.reasoningEffort ?? "medium",
            context: context
        )
        do {
            if let existing = try store.requestedRun(requesterID: threadID, rootRunID: rootRunID, clientRequestID: requestID) {
                try store.deleteThread(id: child.id)
                return runJSON(existing)
            }
            guard sessions[threadID]?.turn?.id == callerTurn.id else { throw CancellationError() }
            try store.setParent(child.id, parentID: threadID, accountID: account)
            if let title = args["title"]?.stringValue?.nilIfBlank { try store.updateThread(id: child.id, title: String(title.prefix(256))) }
            let run = try queueAgentRun(
                targetID: child.id,
                caller: caller,
                turn: callerTurn,
                input: input,
                requestID: requestID,
                arguments: args,
                context: context
            )
            Task { await self.scheduleRuns(accountID: account) }
            return runJSON(run)
        } catch {
            try? store.deleteThread(id: child.id)
            throw error
        }
    }

    func waitForThreads(
        arguments args: [String: JSONValue],
        threadID: String,
        processID: UUID,
        callerTurn: Turn,
        account: String
    ) async throws -> JSONValue {
        let store = try history()
        guard let ids = args["thread_ids"]?.arrayValue?.compactMap(\.stringValue), !ids.isEmpty, ids.count <= 20,
              !ids.contains(threadID) else { throw PiRuntimeError.invalidProtocolResponse }
        for id in ids {
            _ = try store.thread(id: id, accountID: account)
        }
        let seconds = min(max(args["timeout_seconds"]?.intValue ?? 30, 1), 60)
        guard waitingParents.insert(threadID).inserted
        else { throw PiRuntimeError.rpcError(code: nil, message: "Already waiting in this thread") }
        defer { waitingParents.remove(threadID) }
        await scheduleRuns(accountID: account)
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while true {
            try Task.checkCancellation()
            // A stop or a turn that is gone ends the wait with a result, not an error the next turn would inherit.
            guard let turn = sessions[threadID]?.turn, turn.id == callerTurn.id, sessions[threadID]?.processID == processID,
                  !turn.stopRequested else { return .object(["error": .string("The wait was stopped")]) }
            let runs = try ids.compactMap { try store.latestRun(threadID: $0) }
            let delivered = try store.undeliveredRuns(requesterID: threadID).filter { ids.contains($0.threadID) }
            // Results already received do not end a wait; only a new one, or nothing left to wait for, does.
            let pending = runs.contains { ["queued", "running", "waitingForUser"].contains($0.status) }
            let timedOut = ContinuousClock.now >= deadline
            if !delivered.isEmpty || !pending || timedOut {
                try store.markRunsDelivered(delivered)
                return try .object([
                    "runs": .array(runs.map { runJSON($0) }),
                    "results": .string(notificationText(delivered, accountID: account)),
                    "timed_out": .bool(timedOut),
                    "next": timedOut ? .string("Results reach this thread automatically once it is idle. End your turn instead of waiting again.") :
                        .null,
                ])
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    func queueAgentRun(
        targetID: String,
        caller: ChatThreadRecord,
        turn: Turn,
        input: String,
        requestID: String,
        arguments: [String: JSONValue],
        context: CodexChatContext? = nil
    ) throws -> ChatRunRecord {
        let text = context.map { CodexChatPromptCodec.encode(text: input, context: $0) } ?? input
        let run = try history().enqueueRun(ChatRunRecord(
            id: .v7(),
            threadID: targetID,
            requestedByThreadID: caller.id,
            rootRunID: turn.run.rootRunID,
            status: "queued",
            input: agentRequestText(text, callerID: caller.id),
            model: arguments["model"]?.stringValue,
            effort: arguments["effort"]?.stringValue ?? caller.reasoningEffort ?? "medium",
            approvalMethod: sessions[caller.id]?.approvalMethod?.rawValue ?? "ask",
            clientRequestID: requestID,
            createdAt: .now
        ))
        publishStates()
        return run
    }

    /// JSON escaping keeps agent text (including forged closing tags) inside its provenance envelope.
    func agentRequestText(_ input: String, callerID: String) throws -> String {
        let payload: JSONValue = .object([
            "thread_id": .string(callerID),
            "input": .string(String(input.prefix(32000))),
        ])
        let json = try String(decoding: JSONEncoder().encode(payload), as: UTF8.self)
        return "<thread_request source=\"dahlia\" untrusted=\"true\">\n\(json)\n</thread_request>"
    }

    func runJSON(_ run: ChatRunRecord, delivery: String? = nil) -> JSONValue {
        let status = (try? history().run(id: run.id))?.status ?? run.status
        var json: [String: JSONValue] = ["run_id": .string(run.id.uuidString), "thread_id": .string(run.threadID), "status": .string(status)]
        if let delivery { json["delivery"] = .string(delivery) }
        return .object(json)
    }
}
