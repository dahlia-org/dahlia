import DahliaRuntimeSupport
import Foundation
import GRDB

/// hermes-agent-self-evolution for one account skill: the chat tool `skill_optimize` (pi-hermes-skills `optimizer.ts`) runs GEPA in the
/// conversation, and the evolved SKILL.md waits in the skill's history for the user's approval.
extension PiChatService {
    /// The newest user requests and their replies that the optimizer mines for evaluation examples.
    static let optimizerMessageLimit = 300

    /// Starts a run: the skill, the account's other conversations, and the run that records the outcome.
    func optimizerInput(_ payload: JSONValue, run turn: ChatRunRecord, account: String, root: URL) async throws -> JSONValue {
        guard turn.origin == "user" else { throw HermesLearning.failure("Only a user conversation can optimize skills.") }
        let name = payload.objectValue?["name"]?.stringValue ?? ""
        let before = try await skillService().editableSnapshot(name: name, account: account, root: root)
        guard let data = before.files["SKILL.md"], let raw = String(data: data, encoding: .utf8)
        else { throw HermesLearning.failure("Skill is not UTF-8 text.") }
        let messages = try await recentRequests(account: account, excluding: turn.threadID)
        let run = try AgentSystemRunRecord(
            id: UUID.v7().uuidString, accountID: account, task: "optimizer", status: "running", summary: name, report: HermesLearning.json(before),
            startedAt: .now
        )
        try startOptimizer(run, turn: turn)
        return .object(["run_id": .string(run.id), "name": .string(name), "raw": .string(raw), "messages": .array(messages)])
    }

    /// Registration and turn validation cannot suspend between checking the owner and recording the run.
    private func startOptimizer(_ run: AgentSystemRunRecord, turn: ChatRunRecord) throws {
        guard sessions[turn.threadID]?.turn?.id == turn.id,
              sessions[turn.threadID]?.turn?.stopRequested == false else { throw CancellationError() }
        try history().dbQueue.write { try run.insert($0) }
        optimizerTurns[run.id] = turn.id
    }

    /// Stages an improved skill for approval and finishes the run. Answers whether a proposal was staged.
    func optimizerResult(_ payload: JSONValue, account: String, root: URL) async throws -> JSONValue {
        let object = payload.objectValue ?? [:]
        guard let id = object["run_id"]?.stringValue,
              var run = try await history().dbQueue.read({ try AgentSystemRunRecord.fetchOne($0, key: id) }),
              run.accountID == account, run.task == "optimizer", run.status == "running" else { return .bool(false) }
        defer { optimizerTurns[id] = nil }
        let name = run.summary
        var staged = false
        var failure: String?
        do {
            if let error = object["error"]?.stringValue { throw HermesLearning.failure(error) }
            let number = { (key: String) -> Double in if case let .number(value)? = object[key] { value } else { 0 } }
            let passed = object["constraints"]?.arrayValue?.allSatisfy { $0.objectValue?["passed"] == .bool(true) } ?? false
            let scores = L10n.agentOptimizerScores(baseline: number("baseline_score"), evolved: number("evolved_score"))
            if object["changed"] == .bool(true), passed, number("improvement") > 0, let skill = object["skill"]?.stringValue {
                let before = try JSONDecoder().decode(AgentSkillSnapshot.self, from: Data(run.report.utf8))
                try await skillService()
                    .proposeOptimization(name: name, content: skill, before: before, account: account, root: root, runID: id) { db in
                        guard try String.fetchOne(db, sql: "SELECT status FROM agent_system_runs WHERE id=?", arguments: [id]) == "running"
                        else { throw CancellationError() }
                    }
                staged = true
            }
            run.summary = (staged ? L10n.agentOptimizerProposed(name) : L10n.agentOptimizerNoImprovement(name)) + "\n" + scores
            run.report = try String(decoding: JSONEncoder().encode(payload), as: UTF8.self)
            run.status = "completed"
        } catch {
            failure = error.localizedDescription
            run.status = "failed"
            run.summary = name + "\n" + error.localizedDescription
            run.report = ""
        }
        run.finishedAt = .now
        let finished = run
        try await history().dbQueue.write { db in
            guard try String.fetchOne(db, sql: "SELECT status FROM agent_system_runs WHERE id=?", arguments: [id]) == "running" else { return }
            try finished.save(db)
        }
        if let failure { return .object(["success": .bool(false), "error": .string(failure)]) }
        return .bool(staged)
    }

    /// Every native turn exit also settles tools whose Pi process could no longer call the bridge.
    func finishOptimizers(turnID: UUID) {
        let ids = optimizerTurns.filter { $0.value == turnID }.map(\.key)
        guard !ids.isEmpty else { return }
        do {
            try history().dbQueue.write { db in
                for id in ids {
                    try db.execute(
                        sql: "UPDATE agent_system_runs SET status='interrupted',finishedAt=?,report='' WHERE id=? AND status='running'",
                        arguments: [Date(), id]
                    )
                }
            }
            for id in ids {
                optimizerTurns[id] = nil
            }
        } catch { ErrorReportingService.capture(error, context: ["source": "optimizerRunEnd"]) }
    }

    /// Upstream `HermesSessionImporter`: each request the user typed, paired with the reply that followed it.
    private func recentRequests(account: String, excluding threadID: String) async throws -> [JSONValue] {
        try await history().dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
            SELECT i.threadID, json_extract(i.data,'$.role') AS role, json_extract(i.data,'$.content') AS content, r.origin
            FROM chat_items i JOIN chat_threads t ON t.id=i.threadID LEFT JOIN chat_runs r ON r.id=i.runID
            WHERE t.accountID=? AND t.id<>? AND t.scheduleID IS NULL AND t.id NOT IN (SELECT threadID FROM agent_tasks WHERE threadID IS NOT NULL) AND json_extract(i.data,'$.type')='message'
                AND json_extract(i.data,'$.role') IN ('user','assistant')
            ORDER BY i.createdAt DESC, i.seq DESC LIMIT ?
            """, arguments: [account, threadID, Self.optimizerMessageLimit * 4])
            var pairs: [JSONValue] = []
            // Newest first: the oldest assistant text after a user message, before the next one, is its reply.
            var replies: [String: String] = [:]
            for row in rows {
                let thread: String = row["threadID"]
                let content: String = row["content"] ?? ""
                if row["role"] as String? == "assistant" {
                    replies[thread] = content
                } else if row["origin"] as String? == "user", !content.isEmpty, pairs.count < Self.optimizerMessageLimit {
                    pairs.append(.object(["task_input": .string(content), "assistant_response": .string(replies[thread] ?? "")]))
                    replies[thread] = nil
                } else {
                    replies[thread] = nil
                }
            }
            return pairs
        }
    }
}
