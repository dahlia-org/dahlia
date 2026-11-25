import DahliaRuntimeSupport
import Foundation
import GRDB

/// Hermes `agent/curator.py` for the selected account: an idle, interval-gated pass of deterministic transitions,
/// then the opt-in LLM consolidation in a separate Pi process.
extension PiChatService {
    /// System-run history older than this is removed; the newest run of each task stays as the interval anchor.
    static let systemRunRetentionDays = 30

    /// Housekeeping calls this hourly. Upstream `maybe_run_curator` plus the Dahlia recording and lane gates.
    func maybeRunCurator() async {
        guard await (try? runtime.requireConfigured()) != nil else { return }
        let account = AppAccount.key
        guard SkillCuratorSettings.enabled(account), curatorTask == nil, reviewTask == nil, !AgentBackgroundActivity.isRecording,
              startingTurns.isEmpty, !sessions.values.contains(where: { $0.turn != nil }) else { return }
        do {
            let now = Date()
            let (last, activity) = try await history().dbQueue.read { db in
                try (
                    Date.fetchOne(db, sql: "SELECT MAX(startedAt) FROM agent_system_runs WHERE accountID=? AND task='curator'", arguments: [account]),
                    Date.fetchOne(db, sql: "SELECT MAX(updatedAt) FROM chat_threads WHERE accountID=?", arguments: [account])
                )
            }
            // The first observation seeds the clock and defers one full interval, so a new install never prunes at once.
            guard let last else {
                try await history().dbQueue.write { db in
                    try AgentSystemRunRecord(
                        id: UUID.v7().uuidString, accountID: account, task: "curator", status: "seeded",
                        summary: L10n.agentCuratorSeeded, report: "", startedAt: now, finishedAt: now
                    ).insert(db)
                }
                return
            }
            guard now.timeIntervalSince(last) >= Double(SkillCuratorSettings.intervalHours(account)) * 3600,
                  now.timeIntervalSince(max(activity ?? .distantPast, launchedAt)) >= SkillCuratorSettings.minIdleHours * 3600
            else { return }
            guard curatorTask == nil, reviewTask == nil, startingTurns.isEmpty,
                  !sessions.values.contains(where: { $0.turn != nil }) else { return }
            curatorTask = Task { await self.runCurator() }
        } catch {
            ErrorReportingService.capture(error, context: ["source": "skillCurator"])
        }
    }

    func runCurator() async {
        defer {
            curatorTask = nil
            activeCurator = nil
            curatorReport = nil
        }
        let account = AppAccount.key
        guard startingTurns.isEmpty, !sessions.values.contains(where: { $0.turn != nil }) else { return }
        let generation = curatorActivityGeneration.withLock { $0 }
        let runtime = runtime
        let activityGeneration = curatorActivityGeneration
        let authorize: @Sendable () throws -> Void = {
            guard activityGeneration.withLock({ $0 == generation }), runtime.isConfigured,
                  SkillCuratorSettings.enabled(account), !AgentBackgroundActivity.isRecording
            else { throw CancellationError() }
        }
        let id = UUID.v7().uuidString
        var run = AgentSystemRunRecord(
            id: id, accountID: account, task: "curator", status: "running", summary: "", report: "", startedAt: .now
        )
        var connection: PiRPCConnection?
        do {
            // Persisted before any work, so a crash still counts as the interval's run.
            let started = run
            try await history().dbQueue.write {
                try authorize()
                try started.insert($0)
            }
            let service = try skillService()
            try await service.setCatalog(runtime.skills(), account: account)
            // pi-hermes-skills applies the transitions through `skillStore` and reports the counts and candidates.
            let process = try await connectCurator(runID: id, authorize: authorize)
            connection = process
            _ = try await process.request("prompt", PiRuntimeService.prompt([.text("/hermes-curator")]))
            try authorize()
            guard let report = curatorReport?.objectValue, let counts = report["counts"]?.objectValue
            else { throw PiRuntimeError.turnFailed("Curator did not report.") }
            let count = { (key: String) in counts[key]?.intValue ?? 0 }
            run.summary = L10n.agentCuratorAutoSummary(
                archived: count("archived"), stale: count("markedStale"), reactivated: count("reactivated")
            )
            if !SkillCuratorSettings.consolidate(account) {
                run.summary += "\n" + L10n.agentCuratorConsolidationOff
            } else if let candidates = report["candidates"]?.stringValue {
                let final = try await consolidate(candidates: candidates, runID: id, connection: process, authorize: authorize)
                run.summary += "\n" + (final.isEmpty ? L10n.agentCuratorNoChange : String(final.prefix(240)) + (final.count > 240 ? "…" : ""))
                run.report = String(final.prefix(20000))
            } else {
                run.summary += "\n" + L10n.agentCuratorNoCandidates
            }
            run.status = "completed"
        } catch {
            // A denied transition fails the command; the gate that denied it decides the outcome.
            let cancelled = error is CancellationError || (try? authorize()) == nil
                || (activeCurator?.consolidating == true && !SkillCuratorSettings.consolidate(account))
            run.status = cancelled ? "interrupted" : "failed"
            run.summary += (run.summary.isEmpty ? "" : "\n") + (cancelled ? CancellationError() : error).localizedDescription
        }
        if let connection { await runtime.close(connection) }
        run.finishedAt = .now
        let finished = run
        try? await history().dbQueue.write { try finished.update($0) }
        await learningSkills?.finishReview(id)
    }

    /// A process with only the skill tools, the account's Curator settings, and Hermes's Curator role.
    private func connectCurator(
        runID: String,
        authorize: @escaping @Sendable () throws -> Void
    ) async throws -> PiRPCConnection {
        try authorize()
        let account = AppAccount.key
        let settings = try HermesLearning.json([
            "staleAfterDays": SkillCuratorSettings.staleAfterDays, "archiveAfterDays": SkillCuratorSettings.archiveAfterDays(account),
        ])
        let connection = try await runtime.connect(
            .init(
                mode: .chat, cwd: agentLocator.agentURL(),
                arguments: ["--no-session", "--system-prompt", Self.systemPrompt, "--tools", "skills_list,skill_view,skill_manage"],
                environment: ["DAHLIA_PI_MEMORY_ENABLED": "0", "DAHLIA_PI_CURATOR": "1", "DAHLIA_PI_CURATOR_SETTINGS": settings],
                profile: .review
            )
        ) { [weak self] method, payload in
            guard let self else { throw CancellationError() }
            return try await self.curatorTool(method, payload: payload, runID: runID, authorize: authorize)
        }
        activeCurator = (runID, account, connection, consolidating: false)
        return connection
    }

    /// Upstream `_run_llm_review`: the verbatim curator prompt and the candidate list, with only the skill tools.
    private func consolidate(
        candidates: String,
        runID: String,
        connection: PiRPCConnection,
        authorize: @escaping @Sendable () throws -> Void
    ) async throws -> String {
        activeCurator?.consolidating = true
        let account = AppAccount.key
        // Reviews can take several minutes upstream; a sweep of 100 calls gets half an hour.
        let timeout = Task { try? await Task.sleep(for: .seconds(1800))
            if !Task.isCancelled { await self.runtime.close(connection) }
        }
        defer { timeout.cancel() }
        let model = SkillCuratorSettings.model(account)
        if let slash = model.firstIndex(of: "/") {
            _ = try await connection.request(
                "set_model",
                ["provider": .string(String(model[..<slash])), "modelId": .string(String(model[model.index(after: slash)...]))]
            )
        }
        let effort = SkillCuratorSettings.effort(account)
        if !effort.isEmpty {
            _ = try await connection.request("set_thinking_level", ["level": .string(PiRuntimeService.thinkingLevel(effort))])
        }
        try authorize()
        guard curatorAllowed(runID: runID) else { throw CancellationError() }
        let prompt = (HermesLearning.prompts["curator_review_prompt"] ?? "") + "\n\n" + candidates
        _ = try await connection.request("prompt", PiRuntimeService.prompt([.text(prompt)]))
        var responses = 0
        var lastMessage: [String: JSONValue]?
        for try await event in connection.events {
            try authorize()
            guard curatorAllowed(runID: runID) else { throw CancellationError() }
            let object = event.objectValue ?? [:]
            if object["type"]?.stringValue == "message_end", let message = object["message"]?.objectValue,
               message["role"]?.stringValue == "assistant" {
                responses += 1
                lastMessage = message
                // A successful empty report is valid; an error/abort must never reuse intermediate text.
                _ = try PiRuntimeService.assistantText(message, allowEmpty: true)
                guard responses <= 100 else { throw PiRuntimeError.turnFailed("Curator response limit exceeded.") }
            }
            if object["type"]?.stringValue == "agent_settled" {
                guard object["aborted"] != .bool(true) else { throw CancellationError() }
                return try PiRuntimeService.assistantText(lastMessage, allowEmpty: true).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        throw PiRuntimeError.processExited(nil)
    }

    /// Transitions need only an enabled Curator; consolidation also needs its switch.
    private func curatorActive(runID: String) -> Bool {
        activeCurator?.id == runID && SkillCuratorSettings.enabled(AppAccount.key) && !AgentBackgroundActivity.isRecording
            && runtime.isConfigured
    }

    private func curatorAllowed(runID: String) -> Bool {
        curatorActive(runID: runID) && SkillCuratorSettings.consolidate(AppAccount.key)
    }

    private func curatorTool(
        _ method: String,
        payload: JSONValue,
        runID: String,
        authorize: @escaping @Sendable () throws -> Void
    ) async throws -> JSONValue {
        guard curatorActive(runID: runID) else { throw CancellationError() }
        let service = try skillService()
        let runtime = runtime
        let account = AppAccount.key
        let root = try skillsRoot()
        let running: @Sendable (Database) throws -> Void = { db in
            try authorize()
            try Task.checkCancellation()
            guard try String.fetchOne(db, sql: "SELECT status FROM agent_system_runs WHERE id=?", arguments: [runID]) == "running"
            else { throw CancellationError() }
        }
        switch method {
        case "curatorReport":
            curatorReport = payload
            return .null
        case "skillStore":
            let object = payload.objectValue ?? [:]
            let name = object["name"]?.stringValue ?? ""
            switch object["action"]?.stringValue {
            case "all":
                return try await service.curatorRecords(account: account, root: root)
            case "set":
                guard let expected = object["expected"]?.objectValue else { throw HermesLearning.failure("Expected a skill record snapshot.") }
                return try await .bool(service.setCuratorFields(
                    name: name, fields: object["fields"]?.objectValue ?? [:], account: account, expected: .object(expected), authorize: running
                ))
            case "archive":
                guard let expected = object["expected"]?.objectValue else { throw HermesLearning.failure("Expected a skill record snapshot.") }
                return try await .bool(service.archive(name: name, account: account, root: root, expected: .object(expected), authorize: running))
            default:
                throw HermesLearning.failure("Unknown skill store action.")
            }
        default:
            guard curatorAllowed(runID: runID), method != "memory", PiExecutionProfile.review.allows(method)
            else { throw CancellationError() }
            try await service.setCatalog(runtime.skills(), account: account)
            return try await service.execute(
                method, payload: payload, account: account, root: root, thread: nil, review: runID, curator: true
            ) { db in
                try running(db)
                guard SkillCuratorSettings.consolidate(account) else { throw CancellationError() }
            }
        }
    }

    /// Daily retention: unattended runs are numerous and only their recent history is useful.
    func pruneSystemRuns(now: Date = .now) async {
        let cutoff = now.addingTimeInterval(-Double(Self.systemRunRetentionDays) * 86400)
        try? await history().dbQueue.write { try AgentSystemRunRecord.deleteExpired($0, before: cutoff) }
    }

    /// pi-hermes-skills reports a `/skill:` command or a read of a skill file Pi listed, which upstream counts as use.
    func recordSkillUse(_ payload: JSONValue) async {
        guard let name = payload.objectValue?["name"]?.stringValue, payload.objectValue?["kind"]?.stringValue == "use",
              AgentSkillService.validName(name), let service = try? skillService() else { return }
        try? await service.recordUsage(name: name, account: AppAccount.key, columns: ["useCount"])
    }
}
