import DahliaRuntimeSupport
import Foundation
import GRDB

extension PiChatService {
    /// Modeled on T3's thread tools: a launched thread is top-level and followed by its starter; a delegated task is a
    /// child (a subagent) whose result comes back on its own.
    nonisolated static let readThreadTools = ["thread_list", "thread_search", "thread_read"]
    nonisolated static let manageThreadTools = [
        "thread_launch",
        "delegate_task",
        "task_status",
        "task_cancel",
        "thread_send",
        "thread_wait",
        "thread_interrupt",
        "thread_update",
    ]
    /// The thread tools reach Dahlia under their own names.
    nonisolated static let threadToolMethods = Set(readThreadTools + manageThreadTools)

    func runDidSettle(_ threadID: String, accountID: String? = nil) {
        guard let account = accountID ?? sessions[threadID].map({ _ in AppAccount.key }) else { return }
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
                    && unattendedRunEligible($0, account: accountID)
            }
            let active = sessions.values.filter { AppAccount.key == accountID && $0.turn != nil && $0.turn?.run.origin != "user" }
                .count
            if canReschedule, canStart, active < 3, !stoppingAccounts.contains(accountID) {
                Task { await self.scheduleRuns(accountID: accountID) }
            }
        }
        do {
            try await runtime.requireConfigured()
            guard AppAccount.key == accountID else {
                try await history().dbQueue.write {
                    try $0.execute(
                        sql: "UPDATE chat_runs SET status='interrupted' WHERE status='queued' AND origin <> 'schedule' AND threadID IN (SELECT id FROM chat_threads WHERE accountID=?)",
                        arguments: [accountID]
                    )
                }
                publishStates()
                return
            }
            canReschedule = true
            let candidates = try history().queuedRuns(accountID: accountID).map(\.id)
            for id in candidates {
                guard let run = try history().run(id: id), run.status == "queued" else { continue }
                guard unattendedRunEligible(run, account: accountID) else { continue }
                if run.origin == "schedule" {
                    guard try scheduleService().validateStart(run, account: accountID) else { continue }
                }
                let active = sessions.filter { _, session in
                    AppAccount.key == accountID && session.turn?.run.origin != "user"
                        && session.turn != nil
                }.count
                guard active < 3 else { break }
                guard sessions[run.threadID]?.turn == nil, startingTurns[run.threadID] == nil,
                      try history().run(id: run.id)?.status == "queued" else { continue }
                scheduledRuns[run.threadID] = run
                do {
                    _ = try await beginTurn(
                        threadID: run.threadID,
                        inputs: run.origin == "restart" ? ChatHistoryCodec.decodeInputs(run.input) : [.text(run.input)],
                        model: run.model,
                        effort: run.effort,
                        approvalMethod: CodexChatApprovalMethod(rawValue: run.approvalMethod) ?? .ask
                    )
                } catch {
                    scheduledRuns[run.threadID] = nil
                    // A run that failed after its turn began has already ended; one that never started ends here.
                    if !unattendedRunEligible(run, account: accountID) { continue }
                    if let failed = try history().failQueuedRun(run) {
                        endRun(failed.id, threadID: failed.threadID, accountID: accountID, status: "failed", savingThread: false)
                    }
                }
            }
        } catch {
            canReschedule = false
            ErrorReportingService.capture(error, context: ["source": "chatRunQueue"])
        }
    }

    /// The queue and its final post-preparation claim use the same current eligibility.
    func unattendedRunEligible(_ run: ChatRunRecord, account _: String) -> Bool {
        // Super Agent's notices, and the work it hands to threads, are the always-on agent's: none starts while recording.
        let fromSuperAgent = (run.origin != "user" && run.profile == PiExecutionProfile.bot.rawValue)
            || (run.requestedByThreadID.map(isBotThread) ?? false)
        if run.origin == "schedule" || fromSuperAgent, AgentBackgroundActivity.isRecording { return false }
        if isBotNotice(run) { return (try? inboxService().isPaused()) == false }
        return true
    }

    /// Any unattended turn in Super Agent, including task results and restart continuations.
    func isBotNotice(_ run: ChatRunRecord) -> Bool {
        run.origin != "user" && isSuperAgentThread(run.threadID)
    }

    /// Super Agent's current thread, the one whose thread tools also manage Tasks.
    func isSuperAgentThread(_ threadID: String) -> Bool {
        threadID == AgentBotSettings.botThread(for: AppAccount.key)
    }

    func validateUnattendedStart(threadID: String, account: String) throws {
        guard let queued = scheduledRuns[threadID] else { return }
        guard unattendedRunEligible(queued, account: account) else { throw CancellationError() }
        // A notice belongs to the bot's current thread; a thread replaced meanwhile gets none.
        if queued.origin == "bot" {
            try validateBotActivity()
            guard AgentBotSettings.botThread(for: account) == threadID else { throw CancellationError() }
        }
    }

    func deliverResults(accountID: String) async {
        guard !stoppingAccounts.contains(accountID) else { return }
        do {
            guard runtime.isConfigured, AppAccount.key == accountID else {
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
                // A launched thread waiting for the user shows it on its card; its caller hears once it ends. A subagent's
                // wait still reaches its parent.
                let pending = try history().undeliveredRuns(requesterID: requester).filter {
                    try $0.status != "waitingForUser" || history().thread(id: $0.threadID, accountID: accountID).parentThreadID != nil
                }
                let stopped = try pending.filter {
                    try $0.suppressAutomaticNotification || (history().run(id: $0.rootRunID)?.stoppedByUser == true)
                }
                try history().markRunsDelivered(stopped)
                let runs = pending.filter { run in !stopped.contains(where: { $0.id == run.id }) }
                guard let first = runs.first else { continue }
                let text = try notificationText(runs, accountID: accountID)
                let parent = try history().thread(id: requester, accountID: accountID)
                let id = UUID.v7()
                var run = try ChatRunRecord(
                    id: id,
                    threadID: requester,
                    rootRunID: first.rootRunID,
                    status: "queued",
                    input: text,
                    model: unattended(requester, account: accountID)?.model ?? parent.model,
                    effort: unattended(requester, account: accountID)?.effort ?? parent.reasoningEffort ?? "medium",
                    approvalMethod: chosenApprovalMethod(requester)?.rawValue ?? CodexChatApprovalMethod.autoReview.rawValue,
                    createdAt: .now
                )
                run.profile = launchProfile(requester).rawValue
                try history().enqueueNotification(run, deliveredRuns: runs)
            }
            await scheduleRuns(accountID: accountID)
        } catch {
            ErrorReportingService.capture(error, context: ["source": "chatRunDelivery"])
        }
    }

    /// Super Agent's model and effort for turns that start without the user; other threads keep their own.
    private func unattended(_ threadID: String, account: String) -> (model: String, effort: String?)? {
        guard isSuperAgentThread(threadID) else { return nil }
        return AgentBotSettings.choice(
            model: AgentBotSettings.unattendedModelKey(for: account), effort: AgentBotSettings.unattendedEffortKey(for: account)
        )
    }

    func notificationText(_ runs: [ChatRunRecord], accountID: String) throws -> String {
        let results = try runs.map { run -> JSONValue in
            let record = try history().thread(id: run.threadID, accountID: accountID)
            return .object([
                "run_id": .string(run.id.uuidString),
                "thread_id": .string(run.threadID),
                "title": .string(String(record.title.prefix(256))),
                "status": .string(run.status),
                "model": (run.model ?? record.model).map { .string($0) } ?? .null,
                "started_at": run.startedAt.map { .number($0.timeIntervalSince1970) } ?? .null,
                "completed_at": run.completedAt.map { .number($0.timeIntervalSince1970) } ?? .null,
                "excerpt": .string(run.resultExcerpt),
                // The excerpt is a prefix; the full reply stays in the thread for `thread_read`.
                "truncated": .bool(run.resultExcerpt.count >= ChatThreadStore.resultExcerptLimit),
            ])
        }
        let json = try String(decoding: JSONEncoder().encode(JSONValue.array(results)), as: UTF8.self)
        return "<thread_results source=\"dahlia\" untrusted=\"true\">\n\(json)\n</thread_results>"
    }

    func threadTool(_ method: String, payload: JSONValue, threadID: String, processID: UUID) async throws -> JSONValue {
        guard let callerSession = sessions[threadID], callerSession.processID == processID,
              let callerTurn = callerSession.turn, !callerTurn.stopRequested, [.interactive, .bot].contains(callerSession.profile)
        else { throw CancellationError() }
        let store = try history()
        let account = AppAccount.key
        let caller = try store.thread(id: threadID, accountID: account)
        guard runtime.isConfigured,
              sessions[threadID]?.processID == processID,
              sessions[threadID]?.turn?.id == callerTurn.id,
              sessions[threadID]?.turn?.stopRequested == false else { throw CancellationError() }
        // Some models fill every optional field with "" or null; an empty value means the field was left out.
        let args = (payload.objectValue ?? [:]).filter { _, value in
            switch value {
            case .null, .array([]): false
            case let .string(text): text.nilIfBlank != nil
            default: true
            }
        }
        if let text = args["message"]?.stringValue ?? args["task"]?.stringValue, text.count > 32000 { throw PiRuntimeError.rpcError(
            code: nil,
            message: "Input exceeds 32000 characters"
        ) }
        if let key = args["client_request_id"]?.stringValue, key.count > 256 { throw PiRuntimeError.invalidProtocolResponse }
        let readOnly = ["thread_list", "thread_read", "thread_search"].contains(method)
        // Depth is a property of the run, not only of the thread: work done for another thread never delegates further.
        guard readOnly || (caller.parentThreadID == nil && callerTurn.run.requestedByThreadID == nil) else {
            throw PiRuntimeError.rpcError(code: nil, message: "Work requested by another thread has read-only thread tools")
        }
        // Events go to a thread only from Super Agent, which reads them in its inbox.
        guard args["event_ids"] == nil || isSuperAgentThread(threadID) else {
            throw PiRuntimeError.rpcError(code: nil, message: "event_ids are for Super Agent's thread")
        }
        if let result = try await untargetedThreadTool(
            method, args: args, caller: caller, callerSession: callerSession, callerTurn: callerTurn, processID: processID
        ) { return result }
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

    /// The thread tools that name no existing thread to act on: listing, searching, starting, and following tasks.
    private func untargetedThreadTool(
        _ method: String,
        args: [String: JSONValue],
        caller: ChatThreadRecord,
        callerSession: Session,
        callerTurn: Turn,
        processID: UUID
    ) async throws -> JSONValue? {
        let store = try history()
        let account = caller.accountID
        let threadID = caller.id
        switch method {
        case "thread_list":
            return try store.toolThreadPage(accountID: account, arguments: args)
        case "thread_search":
            return try await searchThreads(args, account: account)
        case "thread_launch":
            return try await launchThread(arguments: args, caller: caller, callerSession: callerSession, callerTurn: callerTurn)
        case "delegate_task":
            let started = try await startChildThread(arguments: args, caller: caller, callerSession: callerSession, callerTurn: callerTurn)
            guard args["mode"]?.stringValue == "wait", let child = started.objectValue?["thread_id"]?.stringValue else { return started }
            let seconds = min(max((args["timeout_ms"]?.intValue ?? 45000) / 1000, 1), 45)
            return try await waitForThread(child, runID: nil, seconds: seconds, threadID: threadID, processID: processID, callerTurn: callerTurn)
        case "task_status", "task_cancel":
            guard let taskID = args["task_id"]?.stringValue, let child = try? store.thread(id: taskID, accountID: account),
                  child.parentThreadID == threadID
            else { throw PiRuntimeError.rpcError(code: nil, message: "No task with that task_id in this thread") }
            return method == "task_status" ? try taskStatus(child.id, requesterID: threadID)
                : try await interruptThread(child.id, arguments: [:], account: account)
        case "thread_wait":
            guard let targetID = args["thread_id"]?.stringValue, targetID != threadID else { throw PiRuntimeError.invalidProtocolResponse }
            _ = try store.thread(id: targetID, accountID: account)
            let seconds = min(max((args["timeout_ms"]?.intValue ?? 30000) / 1000, 1), 60)
            return try await waitForThread(
                targetID, runID: args["run_id"]?.stringValue.flatMap(UUID.init(uuidString:)), seconds: seconds,
                threadID: threadID, processID: processID, callerTurn: callerTurn
            )
        default:
            return nil
        }
    }

    /// Full-text search over threads, leaving out subagent (child) threads as T3's search does.
    private func searchThreads(_ args: [String: JSONValue], account: String) async throws -> JSONValue {
        guard let query = args["query"]?.stringValue?.nilIfBlank else { throw PiRuntimeError.invalidProtocolResponse }
        let store = try history()
        let page = try await MeetingRepository.searchChatPage(
            accountID: account,
            criteria: .init(text: String(query.prefix(1024))),
            offset: 0,
            limit: min(max(args["limit"]?.intValue ?? 50, 1), 50),
            dbQueue: store.dbQueue
        )
        let topLevel = try page.threads.filter { try store.thread(id: $0.id, accountID: account).parentThreadID == nil }
        return .object([
            "threads": .array(topLevel.map { .object(["id": .string($0.id), "title": .string($0.title)]) }),
            "has_more": .bool(page.hasMore),
        ])
    }

    /// A delegated task's state: working while its latest run is queued or running, otherwise its result, which reading
    /// here counts as receiving.
    private func taskStatus(_ childID: String, requesterID: String) throws -> JSONValue {
        let store = try history()
        guard let run = try store.latestRun(threadID: childID) else { throw PiRuntimeError.invalidProtocolResponse }
        let working = ["queued", "running", "waitingForUser"].contains(run.status)
        if !working, run.requestedByThreadID == requesterID {
            try store.markRunsDelivered([run])
        }
        return .object([
            "task_id": .string(childID),
            "run_id": .string(run.id.uuidString),
            "status": .string(run.status),
            "work_state": .string(working ? "working" : "result_available"),
            "summary": working ? .null : .string(run.resultExcerpt),
            "truncated": .bool(run.resultExcerpt.count >= ChatThreadStore.resultExcerptLimit),
        ])
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
        guard let message = args["message"]?.stringValue?.nilIfBlank,
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
        let (input, eventIDs) = try messageWithEvents(message, arguments: args)
        // Only the requester may add input to a run: a turn the user or another thread started is never redirected.
        let ownedTurn = try sessions[targetID]?.turn.flatMap { turn in
            try history().run(id: turn.id)?.requestedByThreadID == caller.id ? turn : nil
        }
        if mode == "steer" || (mode == "auto" && ownedTurn != nil) {
            guard let turn = ownedTurn else {
                throw PiRuntimeError.rpcError(code: nil, message: "Only a running run you requested can be steered; use queue")
            }
            steeredRequests[steerKey] = turn.run
            do {
                try await steer(threadID: targetID, turnID: turn.wireID, inputs: [.text(agentRequestText(input, callerID: caller.id))])
                try continueTask(targetID, eventIDs: eventIDs, caller: caller)
                return runJSON(turn.run, delivery: "steered")
            } catch {
                steeredRequests[steerKey] = nil
                // The run settled first; auto queues the input as the next run instead.
                guard mode == "auto", sessions[targetID]?.turn?.id != turn.id else { throw error }
            }
        }
        let isTaskSender = isSuperAgentThread(caller.id)
        let run = try queueAgentRun(
            targetID: targetID, caller: caller, turn: callerTurn, input: input, requestID: requestID, arguments: args
        ) { db in
            if isTaskSender {
                try AgentInboxService.continueTask(threadID: targetID, eventIDs: eventIDs, in: db)
            }
        }
        // A retry returns its earlier run; the same key for another thread would silently drop this input.
        guard run.threadID == targetID else {
            throw PiRuntimeError.rpcError(code: nil, message: "client_request_id was already used for another thread in this request")
        }
        Task { await self.scheduleRuns(accountID: caller.accountID) }
        return runJSON(run, delivery: "queued")
    }

    /// Super Agent's message with the events it hands over appended, fenced as data, and their IDs.
    private func messageWithEvents(_ message: String, arguments args: [String: JSONValue]) throws -> (String, [String]) {
        let ids = args["event_ids"]?.arrayValue?.compactMap(\.stringValue) ?? []
        guard !ids.isEmpty else { return (message, []) }
        let inbox = try inboxService()
        do {
            let events = try inbox.undecidedEvents(ids)
            let sources = try Dictionary(uniqueKeysWithValues: inbox.sources().map { ($0.id, $0.name) })
            return (message + Self.handedEvents(events, sources: sources), ids)
        } catch let failure as AgentInboxService.Failure {
            throw PiRuntimeError.rpcError(code: nil, message: failure.message)
        }
    }

    /// When Super Agent sends to a Task's thread, the Task is in progress again and the events it handed over are its.
    private func continueTask(_ threadID: String, eventIDs: [String], caller: ChatThreadRecord) throws {
        guard isSuperAgentThread(caller.id) else { return }
        try inboxService().continueTask(threadID: threadID, eventIDs: eventIDs)
    }

    func interruptThread(_ targetID: String, arguments args: [String: JSONValue], account: String) async throws -> JSONValue {
        let store = try history()
        if let raw = args["run_id"]?.stringValue {
            guard let id = UUID(uuidString: raw), try store.run(id: id)?.threadID == targetID else { throw PiRuntimeError.invalidProtocolResponse }
            if sessions[targetID]?.turn?.run.id == id { await abort(threadID: targetID) } else {
                try store.interruptQueuedRun(id)
            }
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
        guard let input = args["task"]?.stringValue?.nilIfBlank else { throw PiRuntimeError.invalidProtocolResponse }
        // A retry with the same key returns the task it started; without a key, each call is a new task.
        let requestID = args["client_request_id"]?.stringValue?.nilIfBlank ?? UUID.v7().uuidString
        let rootRunID = callerTurn.run.rootRunID
        if let existing = try store.requestedRun(requesterID: threadID, rootRunID: rootRunID, clientRequestID: requestID) {
            return taskJSON(existing)
        }
        let context = try store.toolContext(arguments: args, accountID: account)
        let child = try await startThread(
            model: args["model"]?.stringValue ?? callerSession.model,
            effort: args["effort"]?.stringValue ?? caller.reasoningEffort ?? "medium",
            context: context
        )
        do {
            if let existing = try store.requestedRun(requesterID: threadID, rootRunID: rootRunID, clientRequestID: requestID) {
                try store.deleteThread(id: child.id)
                return taskJSON(existing)
            }
            guard sessions[threadID]?.turn?.id == callerTurn.id,
                  sessions[threadID]?.turn?.stopRequested == false else { throw CancellationError() }
            try store.setParent(child.id, parentID: threadID, accountID: account)
            if let title = args["title"]?.stringValue?.nilIfBlank {
                try store.updateThread(id: child.id, title: String(title.prefix(256)))
            }
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
            return taskJSON(run)
        } catch {
            try? store.deleteThread(id: child.id)
            throw error
        }
    }

    private func taskJSON(_ run: ChatRunRecord) -> JSONValue {
        guard case var .object(json) = runJSON(run) else { return runJSON(run) }
        json["task_id"] = .string(run.threadID)
        return .object(json)
    }

    /// A new top-level thread, in the user's history like one they started. Its result does not come back on its own; the
    /// launcher follows it with `thread_read` or `thread_wait`.
    func launchThread(
        arguments args: [String: JSONValue],
        caller: ChatThreadRecord,
        callerSession: Session,
        callerTurn: Turn
    ) async throws -> JSONValue {
        let store = try history()
        guard let title = args["title"]?.stringValue?.nilIfBlank else { throw PiRuntimeError.invalidProtocolResponse }
        // A thread Super Agent launches is a Task: its result comes back to Super Agent, and the events it hands over go to it.
        let isTask = isSuperAgentThread(caller.id)
        let requestID = args["client_request_id"]?.stringValue?.nilIfBlank ?? UUID.v7().uuidString
        if let existing = try store.idleLaunch(requesterID: caller.id, rootRunID: callerTurn.run.rootRunID, clientRequestID: requestID) {
            return idleLaunchJSON(existing, isTask: isTask)
        }
        if let existing = try store.requestedRun(requesterID: caller.id, rootRunID: callerTurn.run.rootRunID, clientRequestID: requestID) {
            return runJSON(existing)
        }
        let context = try store.toolContext(arguments: args, accountID: caller.accountID)
        let thread = try await startThread(
            model: args["model"]?.stringValue ?? callerSession.model,
            effort: args["effort"]?.stringValue ?? caller.reasoningEffort ?? "medium",
            context: context
        )
        do {
            // Model discovery yields; a concurrent call may already have committed this request.
            if let existing = try store.idleLaunch(requesterID: caller.id, rootRunID: callerTurn.run.rootRunID, clientRequestID: requestID) {
                try store.deleteThread(id: thread.id)
                return idleLaunchJSON(existing, isTask: isTask)
            }
            if let existing = try store.requestedRun(requesterID: caller.id, rootRunID: callerTurn.run.rootRunID, clientRequestID: requestID) {
                try store.deleteThread(id: thread.id)
                return runJSON(existing)
            }
            guard sessions[caller.id]?.turn?.id == callerTurn.id,
                  sessions[caller.id]?.turn?.stopRequested == false else { throw CancellationError() }
            let (message, eventIDs) = try args["message"]?.stringValue?.nilIfBlank.map { try messageWithEvents($0, arguments: args) } ?? (nil, [])
            try store.updateThread(id: thread.id, title: String(title.prefix(256)))
            let handoff: @Sendable (Database) throws -> Void = { db in
                if isTask {
                    try AgentInboxService.openTask(
                        threadID: thread.id, title: title, instructions: args["message"]?.stringValue ?? "",
                        eventIDs: eventIDs, in: db
                    )
                }
            }
            let run = try message.map {
                try queueAgentRun(
                    targetID: thread.id, caller: caller, turn: callerTurn, input: $0, requestID: requestID, arguments: args,
                    context: context, notifiesCaller: isTask, updating: handoff
                )
            }
            guard let run else {
                try store.recordIdleLaunch(
                    threadID: thread.id,
                    requesterID: caller.id,
                    rootRunID: callerTurn.run.rootRunID,
                    clientRequestID: requestID,
                    updating: handoff
                )
                return idleLaunchJSON(thread.id, isTask: isTask)
            }
            Task { await self.scheduleRuns(accountID: caller.accountID) }
            guard case var .object(json) = runJSON(run) else { return runJSON(run) }
            json["task"] = .bool(isTask)
            return .object(json)
        } catch {
            try? store.deleteThread(id: thread.id)
            throw error
        }
    }

    private func idleLaunchJSON(_ threadID: String, isTask: Bool) -> JSONValue {
        .object(["thread_id": .string(threadID), "status": .string("idle"), "task": .bool(isTask)])
    }

    /// Waits until the thread's run (its latest, or `runID`) settles or needs the user, or a result of work this thread
    /// requested from it arrives. A result received here is not delivered again.
    func waitForThread(
        _ targetID: String,
        runID: UUID?,
        seconds: Int,
        threadID: String,
        processID: UUID,
        callerTurn: Turn
    ) async throws -> JSONValue {
        let store = try history()
        let account = AppAccount.key
        if let runID { guard try store.run(id: runID)?.threadID == targetID else { throw PiRuntimeError.invalidProtocolResponse } }
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
            let run = try runID.flatMap { try store.run(id: $0) } ?? store.latestRun(threadID: targetID)
            let delivered = try store.undeliveredRuns(requesterID: threadID).filter { $0.threadID == targetID }
            // Results already received do not end a wait; only a new one, or nothing left to wait for, does.
            let pending = run.map { ["queued", "running"].contains($0.status) } ?? false
            let timedOut = ContinuousClock.now >= deadline
            if !delivered.isEmpty || !pending || timedOut {
                try store.markRunsDelivered(delivered)
                return try .object([
                    "run": run.map { runJSON($0) } ?? .null,
                    "results": .string(notificationText(delivered, accountID: account)),
                    "timed_out": .bool(timedOut),
                    "next": timedOut ?
                        .string(
                            "A delegated task's result reaches this thread automatically once it is idle. End your turn instead of waiting again."
                        ) :
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
        context: CodexChatContext? = nil,
        notifiesCaller: Bool = true,
        updating: @Sendable (Database) throws -> Void = { _ in }
    ) throws -> ChatRunRecord {
        guard sessions[caller.id]?.turn?.id == turn.id,
              sessions[caller.id]?.turn?.stopRequested == false else { throw CancellationError() }
        // Super Agent's own thread takes only the user's words and Dahlia's notices; the tasks it delegates may be sent more.
        let target = try history().thread(id: targetID, accountID: caller.accountID)
        guard target.scheduleID == nil, target.parentThreadID != nil || !isBotThread(targetID) else {
            throw HermesLearning.failure(L10n.agentScheduleReadOnly)
        }
        let text = context.map { CodexChatPromptCodec.encode(text: input, context: $0) } ?? input
        var run = try ChatRunRecord(
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
            createdAt: .now,
            requestedByRunID: turn.id
        )
        // A launched thread is followed by its launcher; only delegated work reports back on its own.
        run.suppressAutomaticNotification = !notifiesCaller
        // Super Agent's delegated tasks are its own work, recorded as its, so they stay out of learning too.
        run.profile = launchProfile(targetID).rawValue
        let queued = try history().enqueueRun(run, updating: updating)
        publishStates()
        return queued
    }

    /// JSON escaping keeps agent text (including forged closing tags) inside its provenance envelope.
    func agentRequestText(_ input: String, callerID: String) throws -> String {
        guard input.count <= 32000 else {
            throw PiRuntimeError.rpcError(code: nil, message: "Input including handed events exceeds 32000 characters; send fewer events.")
        }
        let payload: JSONValue = .object([
            "thread_id": .string(callerID),
            "input": .string(input),
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
