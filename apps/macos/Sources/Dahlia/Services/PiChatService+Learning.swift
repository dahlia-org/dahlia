import DahliaRuntimeSupport
import Foundation
import GRDB

extension PiChatService {
    struct ScheduleApproval {
        let payload: JSONValue
        let tools: [String]
        let existing: ChatScheduleRecord?
    }

    func validateScheduledStart(threadID: String, account: String) throws {
        guard let run = scheduledRuns[threadID], run.origin == "schedule" else { return }
        guard !AgentBackgroundActivity.isRecording else { throw CancellationError() }
        guard try scheduleService().validateStart(run, account: account) else { throw CancellationError() }
    }

    func enqueueLearningReview(_ run: ChatRunRecord, account: String) {
        do {
            try enqueueReview(run, account: account)
            Task { await self.drainLearningWork() }
        } catch {
            ErrorReportingService.capture(error, context: ["source": "agentReviewEnqueue"])
        }
    }

    func learningToolResult(_ method: String, payload: JSONValue, threadID: String, processID: UUID) async -> JSONValue {
        do {
            return try await learningTool(method, payload: payload, threadID: threadID, processID: processID)
        } catch {
            return .object(["success": .bool(false), "error": .string(error.localizedDescription)])
        }
    }

    func memoryService() throws -> AgentMemoryService {
        try AgentMemoryService(dbQueue: history().dbQueue)
    }

    func scheduleService() throws -> AgentScheduleService {
        try AgentScheduleService(dbQueue: history().dbQueue)
    }

    func skillService() throws -> AgentSkillService {
        if let learningSkills { return learningSkills }
        let service = try AgentSkillService(dbQueue: history().dbQueue)
        learningSkills = service
        return service
    }

    func skillsRoot() throws -> URL {
        try agentLocator.agentURL().appending(path: "skills")
    }

    func learningTool(_ method: String, payload: JSONValue, threadID: String, processID: UUID) async throws -> JSONValue {
        guard let session = sessions[threadID], session.processID == processID, let turn = session.turn, !turn.stopRequested,
              runtime.isConfigured,
              sessions[threadID]?.processID == processID, sessions[threadID]?.turn?.id == turn.id,
              sessions[threadID]?.turn?.stopRequested == false else { throw CancellationError() }
        let account = AppAccount.key
        if method == "scheduledTool" {
            let name = payload.objectValue?["name"]?.stringValue ?? ""
            return .bool(session.profile == .scheduled && name.hasPrefix("mcp__") && payload.objectValue?["readOnly"] == .bool(true) && session
                .allowedTools.contains(name))
        }
        guard session.profile.allows(method) else { throw HermesLearning.failure("Tool unavailable for this execution profile.") }
        switch method {
        case "memory":
            guard AgentLearningSettings.memoryEnabled(account) else { throw HermesLearning.failure("Memory is disabled.") }
            if turn.run.origin == "user" {
                try learningReset(thread: threadID, column: "memoryTurns")
            }
            return try memoryService().execute(payload, account: account, thread: threadID)
        case "skills_list", "skill_view", "skill_manage":
            let service = try skillService()
            try await service.setCatalog(runtime.skills(), account: account)
            guard sessions[threadID]?.turn?.id == turn.id else { throw CancellationError() }
            if method == "skill_manage", turn.run.origin == "user" {
                try learningReset(thread: threadID, column: "skillIterations")
            }
            return try await service.execute(method, payload: payload, account: account, root: skillsRoot(), thread: threadID)
        case "optimizerInput":
            return try await optimizerInput(payload, run: turn.run, account: account, root: skillsRoot())
        case "cronjob", "cronjobCommit":
            let record = try history().thread(id: threadID, accountID: account)
            guard record.parentThreadID == nil,
                  turn.run.origin == "user" else { throw HermesLearning.failure("Only a user conversation can manage schedules.") }
            if method == "cronjobCommit" {
                guard let id = payload.objectValue?["request_id"]?.stringValue,
                      let approval = sessions[threadID]?.turn?.pendingSchedules.removeValue(forKey: id)
                else { throw HermesLearning.failure("Schedule approval is no longer pending.") }
                guard payload.objectValue?["approved"] == .bool(true) else { throw HermesLearning.failure("The schedule was not approved.") }
                if let existing = approval.existing {
                    guard try scheduleService().record(id: existing.id, account: account).revision == existing.revision
                    else { throw HermesLearning.failure("Schedule changed during approval. Review the new revision.") }
                }
                let result = try scheduleService().execute(
                    approval.payload, account: account, approved: true, tools: approval.tools, expectedRevision: approval.existing?.revision
                )
                Task { await self.drainLearningWork() }
                return result
            }
            let action = payload.objectValue?["action"]?.stringValue ?? ""
            let existing = try payload.objectValue?["job_id"]?.stringValue.map {
                try scheduleService().record(id: $0, account: account)
            }
            let needsApproval = action == "create" || action == "resume" || (action == "update" && existing?.enabled == true)
            let tools = payload.objectValue?["_readOnlyTools"]?.arrayValue?.compactMap(\.stringValue) ?? []
            if needsApproval {
                // The card displays the effective revision, including fields omitted from an update.
                var effective = payload.objectValue ?? [:]
                if action == "resume", let existing {
                    // Resume activates the saved task; it does not apply create/update fields.
                    effective = ["action": .string(action), "job_id": .string(existing.id), "name": .string(existing.name)]
                }
                effective.removeValue(forKey: "_readOnlyTools")
                effective["approved_read_only_tools"] = .array(tools.sorted().map(JSONValue.string))
                effective["prompt"] = effective["prompt"] ?? existing.map { .string($0.prompt) }
                effective["schedule"] = effective["schedule"] ?? existing.map { .string($0.schedule) }
                effective["skills"] = effective["skills"] ?? existing
                    .flatMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.skills.utf8)) }
                effective["revision"] = .number(Double((existing?.revision ?? 0) + 1))
                let approval: JSONValue = .object([
                    "kind": .string("mcpToolCall"), "server": .string("dahlia"), "tool": .string("cronjob"),
                    "arguments": .object(effective), "reason": .string(L10n.agentScheduleApproval),
                ])
                let id = UUID.v7().uuidString
                guard Self.approvalRequest(id: id, payload: approval, mcpServers: session.mcpServers)?.canApprove == true
                else { throw HermesLearning.failure("The schedule is too large to approve.") }
                sessions[threadID]?.turn?.pendingSchedules[id] = ScheduleApproval(payload: payload, tools: tools, existing: existing)
                return .object(["request_id": .string(id), "approval": approval])
            }
            let result = try scheduleService().execute(
                payload,
                account: account,
                approved: false,
                tools: tools,
                expectedRevision: existing?.revision
            )
            Task { await self.drainLearningWork() }
            return result
        default: throw HermesLearning.failure("Unknown learning tool.")
        }
    }

    func learningCount(thread: String, column: String) throws {
        guard ["memoryTurns", "skillIterations"].contains(column) else { return }
        try history().dbQueue.write {
            try $0.execute(sql: "UPDATE chat_threads SET \(column)=\(column)+1 WHERE id=?", arguments: [thread])
        }
    }

    func learningReset(thread: String, column: String) throws {
        guard ["memoryTurns", "skillIterations"].contains(column) else { return }
        try history().dbQueue.write {
            try $0.execute(sql: "UPDATE chat_threads SET \(column)=0 WHERE id=?", arguments: [thread])
        }
    }

    struct ReviewSnapshot: Codable {
        var conversation: String
        var arguments: [String]
        var environment: [String: String]
        var memoryPrompt: String?

        func launchArguments(memoryEnabled: Bool) -> [String] {
            arguments + (memoryEnabled ? memoryPrompt.map { ["--append-system-prompt", $0] } ?? [] : [])
        }
    }

    func enqueueReview(_ run: ChatRunRecord, account: String) throws {
        guard AgentLearningSettings.reviewEnabled(account), run.origin == "user" else { return }
        let store = try history()
        let thread = try store.thread(id: run.threadID, accountID: account)
        let memory = AgentLearningSettings.memoryReviewEnabled(account) && thread.memoryTurns >= AgentLearningSettings.memoryInterval(account)
        let skills = AgentLearningSettings.skillReviewEnabled(account) && thread.skillIterations >= AgentLearningSettings.skillInterval(account)
        guard memory || skills else { return }
        let kinds: [AgentLearningSettings.ReviewKind] = (memory ? [.memory] : []) + (skills ? [.skill] : [])
        let session = sessions[run.threadID]
        // Pi RPC has no supported clone/fork command that can annotate individual mixed-origin messages.
        // Use the planned GRDB fallback; the complete transcript retains sequence and immutable run provenance.
        let snapshot = try store.dbQueue.read { db -> ReviewSnapshot in
            let rows = try Row.fetchAll(db, sql: """
            SELECT i.seq,i.data,r.origin FROM chat_items i LEFT JOIN chat_runs r ON r.id=i.runID WHERE i.threadID=? ORDER BY i.seq
            """, arguments: [run.threadID])
            let conversation = rows.map { row -> String in
                let origin: String? = row["origin"]
                let data: String = row["data"]
                let seq: Int64 = row["seq"]
                return "<item seq=\"\(seq)\" source=\"\(origin == "user" ? "user-conversation" : "machine-or-unknown")\">\n\(data)\n</item>"
            }.joined(separator: "\n")
            return ReviewSnapshot(
                conversation: conversation,
                arguments: session?.reviewArguments ?? [],
                environment: session?.reviewEnvironment ?? [:],
                memoryPrompt: session?.reviewMemoryPrompt
            )
        }
        let savedSnapshot = try HermesLearning.json(snapshot)
        try store.dbQueue.write { db in
            for kind in kinds {
                let review = AgentReviewRecord(
                    id: UUID.v7().uuidString, accountID: account, threadID: run.threadID, kind: kind.rawValue,
                    snapshot: savedSnapshot, effort: AgentLearningSettings.reviewEffort(account, kind: kind), status: "pending", createdAt: .now
                )
                if try Self.queueReview(review, db: db) {
                    let counter = kind == .memory ? "memoryTurns" : "skillIterations"
                    try db.execute(sql: "UPDATE chat_threads SET \(counter)=0 WHERE id=?", arguments: [run.threadID])
                }
            }
        }
    }

    /// At most one pending snapshot of each kind per thread; never replace a running review.
    private static func queueReview(_ review: AgentReviewRecord, db: Database) throws -> Bool {
        let pending = try Bool.fetchOne(
            db, sql: "SELECT EXISTS(SELECT 1 FROM agent_reviews WHERE threadID=? AND kind=? AND status='pending')",
            arguments: [review.threadID, review.kind]
        ) ?? false
        guard !pending else { return false }
        try review.insert(db)
        try db.execute(
            sql: "INSERT INTO jobs_background(indexKind,targetKind,targetKey,availableAt,updatedAt) VALUES('review','agentReview',?,?,?)",
            arguments: [review.id, Date(), Date()]
        )
        return true
    }

    /// Older queued combined reviews retain their snapshot, with one job for each independent model setting.
    func splitCombinedReview(_ job: AgentReviewRecord) throws {
        try history().dbQueue.write { db in
            guard try String.fetchOne(db, sql: "SELECT status FROM agent_reviews WHERE id=?", arguments: [job.id]) == "pending" else { return }
            for kind in AgentLearningSettings.ReviewKind.allCases {
                var split = job
                split.id = UUID.v7().uuidString
                split.kind = kind.rawValue
                split.model = nil
                split.effort = AgentLearningSettings.reviewEffort(job.accountID, kind: kind)
                _ = try Self.queueReview(split, db: db)
            }
            try AgentReviewRecord.deleteOne(db, key: job.id)
        }
    }

    /// The kind a queued review still has after the account's switches, or nil when nothing of it remains.
    nonisolated static func effectiveReviewKind(_ kind: String, account: String) -> String? {
        let memory = kind != "skill" && AgentLearningSettings.memoryReviewEnabled(account)
        let skills = kind != "memory" && AgentLearningSettings.skillReviewEnabled(account)
        return memory && skills ? "combined" : memory ? "memory" : skills ? "skill" : nil
    }

    func drainLearningWork() async {
        do {
            try await runtime.requireConfigured()
            let account = AppAccount.key
            if let activeReview, activeReview.account != account || AgentBackgroundActivity.isRecording ||
                Self.effectiveReviewKind(activeReview.kind, account: activeReview.account) != activeReview.kind {
                await runtime.close(activeReview.connection)
            }
            if let activeCurator, activeCurator.account != account || AgentBackgroundActivity.isRecording ||
                !SkillCuratorSettings.enabled(account) || (activeCurator.consolidating && !SkillCuratorSettings.consolidate(account)) {
                await runtime.close(activeCurator.connection)
            }
            try await history().dbQueue.write { db in
                try db.execute(
                    sql: "DELETE FROM jobs_background WHERE indexKind='review' AND targetKey IN (SELECT id FROM agent_reviews WHERE accountID=? AND status='pending') AND ?=0",
                    arguments: [account, AgentLearningSettings.reviewEnabled(account)]
                )
                try db.execute(
                    sql: "UPDATE agent_reviews SET status='cancelled',snapshot='' WHERE accountID=? AND status='pending' AND ?=0",
                    arguments: [account, AgentLearningSettings.reviewEnabled(account)]
                )
            }
            guard !AgentBackgroundActivity.isRecording else { return }
            try scheduleService().tick(account: account)
            await scheduleRuns(accountID: account)
            // Reviews and the Curator's consolidation share one background lane.
            guard reviewTask == nil, curatorTask == nil, AgentLearningSettings.reviewEnabled(account) else { return }
            if let job = try await history().dbQueue.read({
                try AgentReviewRecord.fetchOne(
                    $0,
                    sql: "SELECT * FROM agent_reviews WHERE accountID=? AND status='pending' ORDER BY createdAt LIMIT 1",
                    arguments: [account]
                ) }) {
                reviewTask = Task { await self.runReview(job) }
            }
        } catch {
            // Missing selected-account authentication is a waiting condition; no other account is substituted.
        }
    }

    private func runReview(_ job: AgentReviewRecord) async {
        defer { reviewTask = nil
            activeReview = nil
        }
        do {
            guard !AgentBackgroundActivity.isRecording, AgentLearningSettings.reviewEnabled(job.accountID),
                  runtime.isConfigured else { return }
            guard let kind = Self.effectiveReviewKind(job.kind, account: job.accountID) else {
                try finishReview(job, status: "cancelled")
                return
            }
            if kind == "combined" {
                try splitCombinedReview(job)
                return
            }
            let reviewKind: AgentLearningSettings.ReviewKind = kind == "memory" ? .memory : .skill
            let models = try await runtime.models(forceRefresh: false)
            guard let model = AgentLearningSettings.prepareReviewModel(job.accountID, kind: reviewKind, models: models)
            else { throw PiRuntimeError.requestedModelUnavailable("") }
            let effort = AgentLearningSettings.reviewEffort(job.accountID, kind: reviewKind)
            let memoryEnabled = kind != "skill"
            let snapshot = try JSONDecoder().decode(ReviewSnapshot.self, from: Data(job.snapshot.utf8))
            let work = try agentLocator.agentURL()
            var environment = snapshot.environment
            environment["DAHLIA_PI_MEMORY_ENABLED"] = kind == "skill" || !memoryEnabled ? "0" : "1"
            let args = snapshot.arguments
                .isEmpty ? ["--system-prompt", Self.systemPrompt, "--tools", "memory,skills_list,skill_view,skill_manage"] : snapshot
                .launchArguments(memoryEnabled: memoryEnabled)
            let claimed = try await history().dbQueue.write { db in
                try db.execute(sql: "UPDATE agent_reviews SET status='running' WHERE id=? AND status='pending'", arguments: [job.id])
                return db.changesCount == 1
            }
            guard claimed else { return }
            let connection = try await runtime.connect(
                .init(mode: .chat, cwd: work, arguments: ["--no-session"] + args, environment: environment, profile: .review)
            ) { [weak self] method, payload in
                guard let self else { throw CancellationError() }
                return try await self.reviewTool(method, payload: payload, job: job)
            }
            activeReview = (job.id, job.accountID, connection, kind)
            let timeout = Task { try? await Task.sleep(for: .seconds(600))
                if !Task.isCancelled { await self.runtime.close(connection) }
            }
            do {
                if let slash = model.firstIndex(of: "/") {
                    _ = try await connection.request(
                        "set_model",
                        ["provider": .string(String(model[..<slash])), "modelId": .string(String(model[model.index(after: slash)...]))]
                    )
                }
                _ = try await connection.request("set_thinking_level", ["level": .string(PiRuntimeService.thinkingLevel(effort))])
                let state = try await connection.request("get_state")
                let window = state.objectValue?["model"]?.objectValue?["contextWindow"]?.intValue
                let tokenBudget = window.map { min(600_000.0, Double($0) * 0.75) } ?? 120_000
                let prompt = (HermesLearning.prompts[kind + "_review_prompt"] ?? "") +
                    "\n\nYou can only call " + (kind == "skill" ? "skill " : "memory and skill ") +
                    "management tools. Other tools will be denied at runtime — do not attempt them.\n\n<conversation_snapshot>\n" +
                    snapshot.conversation + "\n</conversation_snapshot>"
                guard activeReview?.id == job.id, Self.effectiveReviewKind(kind, account: job.accountID) == kind,
                      !AgentBackgroundActivity.isRecording,
                      runtime.isConfigured else { throw CancellationError() }
                _ = try await connection.request("prompt", PiRuntimeService.prompt([.text(prompt)]))
                var iterations = 0
                var inputTokens = 0.0
                for try await event in connection.events {
                    guard Self.effectiveReviewKind(kind, account: job.accountID) == kind, !AgentBackgroundActivity.isRecording,
                          runtime.isConfigured else { throw CancellationError() }
                    if event.objectValue?["type"]?.stringValue == "message_end", let message = event.objectValue?["message"]?.objectValue,
                       message["role"]?.stringValue == "assistant" {
                        iterations += 1
                        let usage = message["usage"]?.objectValue ?? [:]
                        inputTokens += ["input", "cacheRead", "cacheWrite"].reduce(0.0) { $0 + Double(usage[$1]?.intValue ?? 0) }
                        if iterations >= 16 || inputTokens >= tokenBudget { break }
                    }
                    if event.objectValue?["type"]?.stringValue == "agent_settled" { break }
                }
                timeout.cancel()
                await runtime.close(connection)
                try finishReview(job, status: "completed")
            } catch {
                timeout.cancel()
                await runtime.close(connection)
                throw error
            }
        } catch {
            try? finishReview(job, status: "interrupted")
        }
        await learningSkills?.finishReview(job.id)
    }

    private func reviewTool(_ method: String, payload: JSONValue, job: AgentReviewRecord) async throws -> JSONValue {
        guard let active = activeReview, active.id == job.id, !AgentBackgroundActivity.isRecording,
              runtime.isConfigured, PiExecutionProfile.review.allows(method) else { throw CancellationError() }
        if method == "memory" {
            guard active.kind != "skill",
                  AgentLearningSettings.memoryReviewEnabled(job.accountID)
            else { throw HermesLearning.failure("Memory is unavailable for this review.") }
            return try memoryService().execute(
                payload,
                account: job.accountID,
                thread: job.threadID,
                review: job.id,
                authorize: Self.reviewAuthorization(job, runtime: runtime, requiresMemory: true)
            )
        }
        guard active.kind != "memory",
              AgentLearningSettings.skillReviewEnabled(job.accountID) else { throw HermesLearning.failure("Skills are unavailable for this review.") }
        let service = try skillService()
        try await service.setCatalog(runtime.skills(), account: job.accountID)
        return try await service.execute(
            method,
            payload: payload,
            account: job.accountID,
            root: skillsRoot(),
            thread: job.threadID,
            review: job.id,
            authorize: Self.reviewAuthorization(job, runtime: runtime)
        )
    }

    nonisolated static func reviewAuthorization(
        _ job: AgentReviewRecord, runtime: PiRuntimeService, requiresMemory: Bool = false
    ) -> @Sendable (Database) throws -> Void {
        { db in
            try Task.checkCancellation()
            guard runtime.isConfigured, !AgentBackgroundActivity.isRecording,
                  requiresMemory ? AgentLearningSettings.memoryReviewEnabled(job.accountID) : AgentLearningSettings.skillReviewEnabled(job.accountID),
                  try AgentReviewRecord.fetchOne(db, key: job.id)?.status == "running" else { throw CancellationError() }
        }
    }

    func finishReview(_ job: AgentReviewRecord, status: String) throws {
        let didNotify = try history().dbQueue.write { db in
            let hasChanges = try Bool
                .fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM agent_learning_changes WHERE reviewID=?)", arguments: [job.id]) ?? false
            let notified = try Bool.fetchOne(db, sql: "SELECT notified FROM agent_reviews WHERE id=?", arguments: [job.id]) ?? false
            if hasChanges, !notified {
                let first = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM agent_reviews WHERE accountID=? AND notified=1",
                    arguments: [job.accountID]
                ) == 0
                let content = L10n.agentLearningUpdated + (first ? "\n" + L10n.agentLearningDefaultHelp : "")
                try ChatThreadStore.append(
                    [.object(["type": .string("thread_notification"), "content": .string(content), "review_id": .string(job.id)])],
                    threadID: job.threadID,
                    inferRunID: false,
                    in: db
                )
                try db.execute(sql: "UPDATE agent_reviews SET notified=1 WHERE id=?", arguments: [job.id])
            }
            try db.execute(sql: "UPDATE agent_reviews SET status=?,snapshot='' WHERE id=?", arguments: [status, job.id])
            let changes = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM agent_learning_changes WHERE reviewID=?", arguments: [job.id]) ?? 0
            let task = switch job.kind {
            case "memory": "memoryReview"
            case "skill": "skillReview"
            default: "review"
            }
            try AgentSystemRunRecord(
                id: UUID.v7().uuidString, accountID: job.accountID, task: task, status: status,
                summary: L10n.agentSystemRunReviewSummary(kind: job.kind, changes: changes), report: "",
                startedAt: job.createdAt, finishedAt: .now
            ).insert(db)
            try db.execute(sql: "DELETE FROM jobs_background WHERE indexKind='review' AND targetKey=?", arguments: [job.id])
            return hasChanges && !notified
        }
        if didNotify, let id = UUID(uuidString: job.id) {
            settledRuns[job.threadID] = (job.accountID, id, false)
            publishStates()
        }
    }

    func notifySchedule(_ run: ChatRunRecord) async {
        guard await (try? runtime.requireConfigured()) != nil,
              let row = try? scheduleService().list(account: AppAccount.key).first(where: { $0.threadID == run.threadID }),
              row.notify else { return }
        await MeetingNotificationService.shared.deliverAgentSchedule(name: row.name, threadID: row.threadID)
    }
}
