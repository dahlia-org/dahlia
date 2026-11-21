import DahliaRuntimeSupport
import Foundation
import GRDB

/// Hermes `tools/skill_usage.py` and the deterministic half of `agent/curator.py`, on `agent_skill_states`.
struct SkillCurationState: Sendable, Equatable {
    var name: String
    var createdBy: String
    var state: String
    var pinned: Bool
    var locked: Bool
    /// Upstream manages only skills that a background pass created.
    var isCuratorManaged: Bool { createdBy == "agent" }
}

/// Upstream `provenance()`: who owns a skill. Only `account` skills that a background pass created (`createdBy='agent'`) are curated.
enum SkillProvenance: String, Sendable {
    /// Shipped in the app bundle (upstream `bundled`).
    case bundled
    /// Installed by a Pi package (upstream `hub`, which Dahlia does not have).
    case package
    /// In the account's own skills directory (upstream `agent`, renamed so it is not confused with `createdBy='agent'`).
    case account

    static func of(name: String, file: URL?, root: URL) -> Self {
        if PiBundle.presetSkillNames.contains(name) { return .bundled }
        guard let file else { return .account }
        return file.deletingLastPathComponent().deletingLastPathComponent().path == PiSandbox.realPath(root) ? .account : .package
    }
}

struct SkillCuratorCounts: Sendable, Equatable {
    var checked = 0
    var markedStale = 0
    var archived = 0
    var reactivated = 0
    var seeded = 0
}

extension AgentSkillService {
    private static let stamps = ["useCount": "lastUsedAt", "viewCount": "lastViewedAt", "patchCount": "lastPatchedAt"]

    /// Usage telemetry for every skill, whoever owns it; only the counters and their timestamps change.
    func recordUsage(name: String, account: String, columns: [String]) throws {
        try dbQueue.write { try Self.recordUsage($0, name: name, account: account, columns: columns) }
    }

    static func recordUsage(_ db: Database, name: String, account: String, columns: [String], now: Date = .now) throws {
        try db.execute(
            sql: "INSERT OR IGNORE INTO agent_skill_states(accountID,name,createdBy,locked,createdAt) VALUES(?,?,'user',0,?)",
            arguments: [account, name, now]
        )
        let assignments = columns.compactMap { column in stamps[column].map { "\(column)=\(column)+1,\($0)=:now" } }
        guard !assignments.isEmpty else { return }
        try db.execute(
            sql: "UPDATE agent_skill_states SET \(assignments.joined(separator: ",")) WHERE accountID=:account AND name=:name",
            arguments: ["now": now, "account": account, "name": name]
        )
    }

    /// Pi loads a skill by reading its SKILL.md; that read is the upstream "use".
    func recordRead(path: String, account: String, root: URL) {
        let url = URL(filePath: PiSandbox.realPath(URL(filePath: (path as NSString).expandingTildeInPath)))
        guard url.lastPathComponent == "SKILL.md" else { return }
        let directory = url.deletingLastPathComponent()
        let name = catalogs[account]?.first(where: { $0.value == url })?.key
            ?? (directory.deletingLastPathComponent().path == PiSandbox.realPath(root) ? directory.lastPathComponent : nil)
        guard let name, Self.validName(name) else { return }
        try? recordUsage(name: name, account: account, columns: ["useCount"])
    }

    /// Skill names, most recently used, viewed or created first, for the chat's budgeted skill index.
    func indexRank(account: String) throws -> [String] {
        try dbQueue.read {
            try String.fetchAll($0, sql: """
            SELECT name FROM agent_skill_states WHERE accountID=? AND state!='archived'
            ORDER BY MAX(COALESCE(lastUsedAt,''),COALESCE(lastViewedAt,''),COALESCE(createdAt,'')) DESC, name
            """, arguments: [account])
        }
    }

    func isPinned(name: String, account: String) throws -> Bool {
        try dbQueue.read {
            try Bool.fetchOne($0, sql: "SELECT pinned FROM agent_skill_states WHERE accountID=? AND name=?", arguments: [account, name]) ?? false
        }
    }

    /// Like `hermes curator pin`, only Curator-managed skills can be pinned.
    func setPinned(name: String, account: String, pinned: Bool) throws {
        try dbQueue.write {
            try $0.execute(
                sql: "UPDATE agent_skill_states SET pinned=? WHERE accountID=? AND name=? AND createdBy='agent'",
                arguments: [pinned, account, name]
            )
        }
    }

    /// Hands an account skill to the Curator (upstream `hermes curator adopt`) or takes it back. A skill taken back is
    /// treated like one the user made, and its pin is cleared because only managed skills can be pinned.
    func setCuratorManaged(name: String, account: String, managed: Bool, now: Date = .now) throws {
        try dbQueue.write {
            try $0.execute(sql: """
            INSERT INTO agent_skill_states(accountID,name,createdBy,locked,createdAt) VALUES(?,?,?,0,?)
            ON CONFLICT(accountID,name) DO UPDATE SET createdBy=excluded.createdBy,
                createdAt=COALESCE(agent_skill_states.createdAt,excluded.createdAt),
                pinned=CASE WHEN excluded.createdBy='agent' THEN agent_skill_states.pinned ELSE 0 END
            """, arguments: [account, name, managed ? "agent" : "user", now])
        }
    }

    func curationStates(account: String) throws -> [SkillCurationState] {
        try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT name,createdBy,state,pinned,locked FROM agent_skill_states WHERE accountID=? ORDER BY name",
                arguments: [account]
            ).map { SkillCurationState(name: $0["name"], createdBy: $0["createdBy"], state: $0["state"], pinned: $0["pinned"], locked: $0["locked"]) }
        }
    }

    /// Skills that a schedule loads. Dahlia does not rewrite approved schedules, so these are never archived.
    func scheduleSkills(account: String) throws -> Set<String> {
        try dbQueue.read { db in
            try Set(String.fetchAll(db, sql: "SELECT skills FROM chat_schedules WHERE accountID=?", arguments: [account]).flatMap {
                (try? JSONDecoder().decode([String].self, from: Data($0.utf8))) ?? []
            })
        }
    }

    /// Curator may edit only its own unprotected skills. Interactive and ordinary review edits retain their permissions.
    static func authorizeCuration(_ db: Database, name: String, account: String, creating: Bool = false) throws {
        if creating { return }
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT createdBy,pinned,locked FROM agent_skill_states WHERE accountID=? AND name=?",
            arguments: [account, name]
        ),
            row["createdBy"] == "agent", !(row["pinned"] as Bool), !(row["locked"] as Bool)
        else { throw HermesLearning.failure("Curator cannot change a user-created, pinned, or locked skill.") }
        let schedules = try String.fetchAll(db, sql: "SELECT skills FROM chat_schedules WHERE accountID=?", arguments: [account])
        guard !schedules.contains(where: { ((try? JSONDecoder().decode([String].self, from: Data($0.utf8))) ?? []).contains(name) })
        else { throw HermesLearning.failure("Curator cannot change a skill used by a scheduled task.") }
    }

    /// Upstream `_background_review_delete_guard`, `_curator_consolidation_delete_guard` and the `absorbed_into`
    /// existence check in `_delete_skill`, plus Dahlia's schedule references, which it does not rewrite.
    func backgroundDeleteGuard(name: String, absorbedInto: String?, account: String, catalog: [String: URL]) throws {
        let owner = try dbQueue.read {
            try String.fetchOne($0, sql: "SELECT createdBy FROM agent_skill_states WHERE accountID=? AND name=?", arguments: [account, name])
        }
        guard owner == "agent" else { throw HermesLearning.failure("Autonomous deletion is limited to agent-created skills.") }
        guard try !scheduleSkills(account: account).contains(name) else {
            throw HermesLearning.failure("Skill '\(name)' is used by a scheduled task. Autonomous maintenance cannot archive it; keep it active.")
        }
        let target = absorbedInto?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !target.isEmpty else {
            throw HermesLearning.failure(
                "Refusing background curator delete of skill '\(name)': the consolidation pass may only archive a skill it has absorbed into an umbrella. Pass absorbed_into=<umbrella> (the umbrella must already exist) to record a verified consolidation. Pruning a skill with no forwarding target is not permitted here — the deterministic inactivity prune handles staleness archival separately. Keeping '\(name)' active."
            )
        }
        guard target != name else { throw HermesLearning.failure("absorbed_into='\(target)' cannot equal the skill being deleted.") }
        guard catalog[target] != nil else {
            throw HermesLearning.failure(
                "absorbed_into='\(target)' does not exist. Create or patch the umbrella skill first, then retry the delete."
            )
        }
    }

    /// Moves the package to `skills/.archive/` (Pi skips dot directories), never deleting it.
    func archive(
        name: String,
        account: String,
        root: URL,
        source changeSource: String = "curator",
        thread: String? = nil,
        review: String? = nil,
        authorize: @Sendable (Database) throws -> Void = { _ in }
    ) throws {
        switch provenance(name: name, account: account, root: root) {
        case .bundled: throw HermesLearning.failure("skill '\(name)' is a bundled built-in; it is never archived or consolidated")
        case .package: throw HermesLearning.failure("skill '\(name)' is installed by a Pi package; never archive")
        case .account: break
        }
        let manager = FileManager.default
        let source = root.appending(path: name)
        guard Self.validName(name), manager.fileExists(atPath: source.appending(path: "SKILL.md").path)
        else { throw HermesLearning.failure("skill '\(name)' not found") }
        let snapshot = try Self.package(source)
        let archive = root.appending(path: ".archive")
        try manager.createDirectory(at: archive, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var destination = archive.appending(path: name)
        if manager.fileExists(atPath: destination.path) {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "yyyyMMddHHmmss"
            destination = archive.appending(path: "\(name)-\(formatter.string(from: .now))")
        }
        try move(source, to: destination) { db in
            try authorize(db)
            try Self.authorizeCuration(db, name: name, account: account)
            try AgentLearningChangeRecord(
                id: .v7(), accountID: account, kind: "skill", target: name,
                before: HermesLearning.json(snapshot), after: nil, status: "applied",
                source: changeSource, threadID: thread, reviewID: review, createdAt: .now
            ).insert(db)
            try db.execute(
                sql: "UPDATE agent_skill_states SET state='archived',archivedAt=? WHERE accountID=? AND name=?",
                arguments: [Date(), account, name]
            )
        }
    }

    /// Upstream `restore_skill`: the exact name first, then its newest timestamped duplicate.
    func restore(name: String, account: String, root: URL) throws {
        let archive = root.appending(path: ".archive")
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: archive.path)) ?? []
        let prefix = name + "-"
        let duplicates = entries.filter {
            $0.hasPrefix(prefix) && $0.count - prefix.count == 14 && $0.dropFirst(prefix.count).allSatisfy(\.isNumber)
        }
        guard Self.validName(name), let found = entries.contains(name) ? name : duplicates.max()
        else { throw HermesLearning.failure("skill '\(name)' not found in archive") }
        if provenance(name: name, account: account, root: root) != .account {
            throw HermesLearning.failure("skill '\(name)' is now bundled or package-installed; restore would shadow the upstream version")
        }
        let destination = root.appending(path: name)
        guard !FileManager.default.fileExists(atPath: destination.path)
        else { throw HermesLearning.failure("destination already exists: \(destination.path)") }
        try move(archive.appending(path: found), to: destination) { db in
            guard try !Self.locked(db, name: name, account: account) else { throw HermesLearning.failure("Skill is locked.") }
            try db.execute(
                sql: "UPDATE agent_skill_states SET state='active',archivedAt=NULL WHERE accountID=? AND name=?",
                arguments: [account, name]
            )
        }
    }

    private func move(_ source: URL, to destination: URL, recording: (Database) throws -> Void) throws {
        try FileManager.default.moveItem(at: source, to: destination)
        do {
            try dbQueue.write(recording)
        } catch {
            try? FileManager.default.moveItem(at: destination, to: source)
            throw error
        }
    }

    /// Upstream `apply_automatic_transitions`: no LLM, pinned, locked and schedule-referenced skills untouched.
    func applyCuratorTransitions(
        account: String,
        root: URL,
        now: Date = .now,
        staleAfterDays: Int,
        archiveAfterDays: Int,
        authorize: @Sendable (Database) throws -> Void = { _ in }
    ) throws -> SkillCuratorCounts {
        let staleCutoff = now.addingTimeInterval(-Double(staleAfterDays) * 86400)
        let archiveCutoff = now.addingTimeInterval(-Double(archiveAfterDays) * 86400)
        let protected = try scheduleSkills(account: account)
        var counts = SkillCuratorCounts()
        for row in try managedRows(account: account, root: root) {
            try dbQueue.read(authorize)
            counts.checked += 1
            let name: String = row["name"]
            let state: String = row["state"]
            if row["pinned"] || row["locked"] || protected.contains(name) { continue }
            // A record from before usage tracking anchors its clock at first sight and waits a full period.
            guard let created: Date = row["createdAt"] else {
                try setField(name: name, account: account, sql: "createdAt=?", value: now, authorize: authorize)
                counts.seeded += 1
                continue
            }
            let anchor = Self.lastActivity(row) ?? created
            if row["useCount"] == 0, anchor > staleCutoff {
                if state == "stale" {
                    try setField(name: name, account: account, sql: "state=?", value: "active", authorize: authorize)
                    counts.reactivated += 1
                }
                continue
            }
            if anchor <= archiveCutoff, state != "archived" {
                try archive(name: name, account: account, root: root, authorize: authorize)
                counts.archived += 1
            } else if anchor <= staleCutoff, state == "active" {
                try setField(name: name, account: account, sql: "state=?", value: "stale", authorize: authorize)
                counts.markedStale += 1
            } else if anchor > staleCutoff, state == "stale" {
                try setField(name: name, account: account, sql: "state=?", value: "active", authorize: authorize)
                counts.reactivated += 1
            }
        }
        return counts
    }

    /// Upstream `_render_candidate_list`, or nil when no skill is Curator-managed.
    func curatorCandidates(account: String, root: URL) throws -> String? {
        let rows = try managedRows(account: account, root: root)
        guard !rows.isEmpty else { return nil }
        let protected = try scheduleSkills(account: account)
        return (["Agent-created skills (\(rows.count)):\n"] + rows.map { row in
            let name: String = row["name"]
            let use: Int = row["useCount"]
            let view: Int = row["viewCount"]
            let patches: Int = row["patchCount"]
            let pinned: Bool = row["pinned"]
            let state: String = row["state"]
            return "- \(name)  provenance=agent  state=\(state)  pinned=\(pinned ? "yes" : "no")  "
                + "cron=\(protected.contains(name) ? "yes" : "no")  activity=\(use + view + patches)  use=\(use)  view=\(view)  "
                + "patches=\(patches)  last_activity=\(Self.lastActivity(row)?.ISO8601Format() ?? "never")"
        }).joined(separator: "\n")
    }

    func provenance(name: String, account: String, root: URL) -> SkillProvenance {
        let file = catalogs[account]?[name]
        // An account skill shadowed by a bundled or package skill of the same name is still not curated.
        return SkillProvenance.of(name: name, file: file, root: root)
    }

    /// Curator-managed skills whose package is still in place.
    private func managedRows(account: String, root: URL) throws -> [Row] {
        try dbQueue.read {
            try Row.fetchAll($0, sql: "SELECT * FROM agent_skill_states WHERE accountID=? AND createdBy='agent' ORDER BY name", arguments: [account])
        }.filter { row in
            let name: String = row["name"]
            return Self.validName(name) && provenance(name: name, account: account, root: root) == .account
                && FileManager.default.fileExists(atPath: root.appending(path: name).appending(path: "SKILL.md").path)
        }
    }

    /// The newest use, view or patch; creation is not activity.
    private static func lastActivity(_ row: Row) -> Date? {
        [row["lastUsedAt"], row["lastViewedAt"], row["lastPatchedAt"]].compactMap { (value: Date?) in value }.max()
    }

    private func setField(
        name: String,
        account: String,
        sql: String,
        value: some DatabaseValueConvertible,
        authorize: @Sendable (Database) throws -> Void
    ) throws {
        try dbQueue.write {
            try authorize($0)
            try Self.authorizeCuration($0, name: name, account: account)
            try $0.execute(sql: "UPDATE agent_skill_states SET \(sql) WHERE accountID=? AND name=?", arguments: [value, account, name])
        }
    }
}
