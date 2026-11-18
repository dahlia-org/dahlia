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
        guard let provider = try? await runtime.currentProvider() else { return }
        let account = provider.accountKey
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
            curatorTask = Task { await self.runCurator(provider: provider) }
        } catch {
            ErrorReportingService.capture(error, context: ["source": "skillCurator"])
        }
    }

    private func runCurator(provider: CodexRuntimeProvider) async {
        defer {
            curatorTask = nil
            activeCurator = nil
        }
        let account = provider.accountKey
        guard startingTurns.isEmpty, !sessions.values.contains(where: { $0.turn != nil }) else { return }
        let generation = curatorActivityGeneration.withLock { $0 }
        let runtime = runtime
        let activityGeneration = curatorActivityGeneration
        let authorize: @Sendable () throws -> Void = {
            guard activityGeneration.withLock({ $0 == generation }), runtime.isSelectedProvider(provider),
                  SkillCuratorSettings.enabled(account), !AgentBackgroundActivity.isRecording
            else { throw CancellationError() }
        }
        let id = UUID.v7().uuidString
        var run = AgentSystemRunRecord(
            id: id, accountID: account, task: "curator", status: "running", summary: "", report: "", startedAt: .now
        )
        do {
            // Persisted before any work, so a crash still counts as the interval's run.
            let started = run
            try await history().dbQueue.write {
                try authorize()
                try started.insert($0)
            }
            let service = try skillService()
            let root = try skillsRoot(provider)
            try await service.setCatalog(runtime.skills(for: provider), account: account)
            let counts = try await service.applyCuratorTransitions(
                account: account, root: root,
                staleAfterDays: SkillCuratorSettings.staleAfterDays, archiveAfterDays: SkillCuratorSettings.archiveAfterDays(account),
                authorize: { _ in try authorize() }
            )
            run.summary = L10n.agentCuratorAutoSummary(archived: counts.archived, stale: counts.markedStale, reactivated: counts.reactivated)
            if !SkillCuratorSettings.consolidate(account) {
                run.summary += "\n" + L10n.agentCuratorConsolidationOff
            } else if let candidates = try await service.curatorCandidates(account: account, root: root) {
                let final = try await consolidate(candidates: candidates, runID: id, provider: provider, authorize: authorize)
                run.summary += "\n" + (final.isEmpty ? L10n.agentCuratorNoChange : String(final.prefix(240)) + (final.count > 240 ? "…" : ""))
                run.report = String(final.prefix(20000))
            } else {
                run.summary += "\n" + L10n.agentCuratorNoCandidates
            }
            run.status = "completed"
        } catch {
            run.status = error is CancellationError ? "interrupted" : "failed"
            run.summary += (run.summary.isEmpty ? "" : "\n") + error.localizedDescription
        }
        run.finishedAt = .now
        let finished = run
        try? await history().dbQueue.write { try finished.save($0) }
        await learningSkills?.finishReview(id)
    }

    /// Upstream `_run_llm_review`: a fork with only the skill tools, the verbatim curator prompt and the candidate list.
    private func consolidate(
        candidates: String,
        runID: String,
        provider: CodexRuntimeProvider,
        authorize: @escaping @Sendable () throws -> Void
    ) async throws -> String {
        try authorize()
        let account = provider.accountKey
        let connection = try await runtime.connect(
            .init(
                mode: .chat, cwd: agentLocator.agentURL(for: provider),
                arguments: ["--no-session", "--system-prompt", Self.systemPrompt, "--tools", "skills_list,skill_view,skill_manage"],
                environment: ["DAHLIA_PI_MEMORY_ENABLED": "0", "DAHLIA_PI_CURATOR": "1"], profile: .review
            ),
            provider: provider
        ) { [weak self] method, payload in
            guard let self else { throw CancellationError() }
            return try await self.curatorTool(method, payload: payload, runID: runID, provider: provider, authorize: authorize)
        }
        activeCurator = (runID, account, connection)
        // Reviews can take several minutes upstream; a sweep of 100 calls gets half an hour.
        let timeout = Task { try? await Task.sleep(for: .seconds(1800))
            if !Task.isCancelled { await self.runtime.close(connection) }
        }
        defer { timeout.cancel() }
        do {
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
            guard curatorAllowed(runID: runID, provider: provider) else { throw CancellationError() }
            let prompt = (HermesLearning.prompts["curator_review_prompt"] ?? "") + "\n\n" + candidates
            _ = try await connection.request("prompt", PiRuntimeService.prompt([.text(prompt)]))
            var responses = 0
            var final = ""
            for try await event in connection.events {
                try authorize()
                guard curatorAllowed(runID: runID, provider: provider) else { throw CancellationError() }
                let object = event.objectValue ?? [:]
                if object["type"]?.stringValue == "message_end", let message = object["message"]?.objectValue,
                   message["role"]?.stringValue == "assistant" {
                    responses += 1
                    let text = (message["content"]?.arrayValue ?? []).compactMap { $0.objectValue?["text"]?.stringValue }.joined()
                    if !text.isEmpty { final = text }
                    if responses >= 100 { break }
                }
                if object["type"]?.stringValue == "agent_settled" { break }
            }
            await runtime.close(connection)
            return final.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            await runtime.close(connection)
            throw error
        }
    }

    private func curatorAllowed(runID: String, provider: CodexRuntimeProvider) -> Bool {
        let account = provider.accountKey
        return activeCurator?.id == runID && SkillCuratorSettings.enabled(account) && SkillCuratorSettings.consolidate(account)
            && !AgentBackgroundActivity.isRecording && runtime.isSelectedProvider(provider)
    }

    private func curatorTool(
        _ method: String,
        payload: JSONValue,
        runID: String,
        provider: CodexRuntimeProvider,
        authorize: @escaping @Sendable () throws -> Void
    ) async throws -> JSONValue {
        guard curatorAllowed(runID: runID, provider: provider), method != "memory", PiExecutionProfile.review.allows(method)
        else { throw CancellationError() }
        let service = try skillService()
        try await service.setCatalog(runtime.skills(for: provider), account: provider.accountKey)
        let runtime = runtime
        let account = provider.accountKey
        return try await service.execute(
            method, payload: payload, account: account, root: skillsRoot(provider), thread: nil, review: runID, curator: true
        ) { db in
            try authorize()
            try Task.checkCancellation()
            guard runtime.isSelectedProvider(provider), SkillCuratorSettings.enabled(account), SkillCuratorSettings.consolidate(account),
                  !AgentBackgroundActivity.isRecording,
                  try String.fetchOne(db, sql: "SELECT status FROM agent_system_runs WHERE id=?", arguments: [runID]) == "running"
            else { throw CancellationError() }
        }
    }

    /// Daily retention: unattended runs are numerous and only their recent history is useful.
    func pruneSystemRuns(now: Date = .now) async {
        let cutoff = now.addingTimeInterval(-Double(Self.systemRunRetentionDays) * 86400)
        try? await history().dbQueue.write { try AgentSystemRunRecord.deleteExpired($0, before: cutoff) }
    }

    func recordSkillRead(path: String, provider: CodexRuntimeProvider) async {
        guard let service = try? skillService(), let root = try? skillsRoot(provider) else { return }
        await service.recordRead(path: path, account: provider.accountKey, root: root)
    }

    /// `/skill:name` loads the skill into the prompt, which upstream counts as use.
    func recordSkillCommand(_ inputs: [CodexAppServerInput], provider: CodexRuntimeProvider) async {
        guard case let .text(text)? = inputs.first, text.hasPrefix("/skill:"),
              let name = text.dropFirst("/skill:".count).split(whereSeparator: \.isWhitespace).first.map(String.init),
              AgentSkillService.validName(name), let service = try? skillService() else { return }
        try? await service.recordUsage(name: name, account: provider.accountKey, columns: ["useCount"])
    }
}
