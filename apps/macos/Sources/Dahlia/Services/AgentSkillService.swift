import DahliaRuntimeSupport
import Foundation
import GRDB

/// The only app writer of account skills. One actor owns validation, ledger capture and replacement together.
actor AgentSkillService {
    let dbQueue: any DatabaseWriter
    private(set) var catalogs: [String: [String: URL]] = [:]
    private var freshReads: [String: [String: String]] = [:]
    init(dbQueue: any DatabaseWriter) { self.dbQueue = dbQueue }

    func setCatalog(_ skills: [CodexChatSlashCommand], account: String) {
        catalogs[account] = Dictionary(
            skills.compactMap { skill in skill.skillFileURL.map { (skill.displayName, URL(filePath: PiSandbox.realPath($0))) } },
            uniquingKeysWith: { first, _ in first }
        )
    }

    func locked(name: String, account: String) throws -> Bool {
        try dbQueue.read { try Self.locked($0, name: name, account: account) }
    }

    static func locked(_ db: Database, name: String, account: String) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT locked FROM agent_skill_states WHERE accountID=? AND name=?", arguments: [account, name]) ?? false
    }

    func setLocked(name: String, account: String, locked: Bool) throws {
        try dbQueue.write {
            try $0.execute(sql: """
            INSERT INTO agent_skill_states(accountID,name,createdBy,locked) VALUES(?,?,'user',?)
            ON CONFLICT(accountID,name) DO UPDATE SET locked=excluded.locked
            """, arguments: [account, name, locked])
        }
    }

    func execute(
        _ method: String,
        payload: JSONValue,
        account: String,
        root: URL,
        thread: String?,
        review: String? = nil,
        curator: Bool = false,
        expectedSnapshots: [String: AgentSkillSnapshot] = [:],
        authorize: @Sendable (Database) throws -> Void = { _ in }
    ) throws -> JSONValue {
        let args = payload.objectValue ?? [:]
        var catalog = catalogs[account] ?? [:]
        if let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) {
            // Discover newly created skills without replacing Pi's winner for a name collision.
            for name in names where Self.validName(name) && catalog[name] == nil {
                let file = root.appending(path: name).appending(path: "SKILL.md")
                if FileManager.default.fileExists(atPath: file.path) { catalog[name] = file }
            }
        }
        switch method {
        case "skills_list":
            let names = args["category"]?.stringValue?.isEmpty == false ? [] : catalog.keys.sorted()
            let skills: [JSONValue] = try names.map { name in
                let text = try Self.read(catalog[name]!, root: catalog[name]!.deletingLastPathComponent())
                return .object(["name": .string(name), "description": .string(Self.description(text) ?? "")])
            }
            return .object([
                "success": .bool(true), "skills": .array(skills), "categories": .array([]), "count": .number(Double(skills.count)),
                "hint": .string("Use skill_view(name) to see full content, tags, and linked files"),
            ])
        case "skill_view":
            guard let name = args["name"]?.stringValue,
                  let file = catalog[name] else { throw HermesLearning.failure("Skill not found. Use skills_list first.") }
            let path = args["file_path"]?.stringValue ?? "SKILL.md"
            let url = try path == "SKILL.md" ? file : Self.file(path, root: file.deletingLastPathComponent())
            let text = try Self.read(url, root: file.deletingLastPathComponent())
            if let review { freshReads[review, default: [:]][name + "/" + path] = text }
            // Upstream counts a view as use too. The Curator's own reads are not evidence of use: they would
            // restart the clock of every skill its consolidation pass inspects.
            if !curator { try recordUsage(name: name, account: account, columns: ["viewCount", "useCount"]) }
            return try .object([
                "success": .bool(true), "name": .string(name), "description": .string(Self.description(text) ?? ""),
                "content": .string(text), "path": .string(url.path), "skill_dir": .string(file.deletingLastPathComponent().path),
                "linked_files": .object(Self.linkedFiles(file.deletingLastPathComponent())),
                "usage_hint": .string(
                    "To view linked files, call skill_view(name, file_path) where file_path is e.g. 'references/api.md' or 'assets/config.yaml'"
                ),
            ])
        case "skill_manage":
            return try mutate(
                args, catalog: catalog, account: account, root: root, thread: thread, review: review, curator: curator,
                expectedSnapshots: expectedSnapshots, authorize: authorize
            )
        default: throw HermesLearning.failure("Unknown skill tool.")
        }
    }

    private func mutate(
        _ args: [String: JSONValue],
        catalog: [String: URL],
        account: String,
        root: URL,
        thread: String?,
        review: String?,
        curator: Bool,
        expectedSnapshots: [String: AgentSkillSnapshot],
        authorize: @Sendable (Database) throws -> Void
    ) throws -> JSONValue {
        guard let operations = args["operations"]?.arrayValue,
              !operations.isEmpty else { throw HermesLearning.failure("Expected a nonempty operations array.") }
        if operations.count > 1,
           operations
           .contains(where: { $0.objectValue?["action"]?.stringValue == "delete" }) {
            throw HermesLearning.failure("delete must be the sole operation.")
        }
        var before: [String: AgentSkillSnapshot?] = [:]
        var working: [String: [String: Data]] = [:]
        for operation in operations {
            guard let op = operation.objectValue, let name = op["name"]?.stringValue, Self.validName(name),
                  let action = op["action"]?.stringValue
            else { throw HermesLearning.failure("Invalid skill operation or name (lowercase, max 64 characters).") }
            guard try !locked(name: name, account: account)
            else { throw HermesLearning.failure("Skill is locked. Unlock it in Settings before changing it.") }
            if let existing = catalog[name],
               PiSandbox.realPath(existing.deletingLastPathComponent()) != PiSandbox.realPath(root.appending(path: name)) {
                throw HermesLearning.failure("Bundled and package skills are read-only. Create an account skill under a different name.")
            }
            let directory = root.appending(path: name)
            if !before.keys.contains(name) {
                let exists = FileManager.default.fileExists(atPath: directory.path)
                let files = exists ? try Self.package(directory) : nil
                if let expected = expectedSnapshots[name], files != expected {
                    throw HermesLearning
                        .failure("Skill changed while editing. Your edits are preserved; reopen the editor to load the latest version.")
                }
                before[name] = .some(files)
                working[name] = files?.files ?? [:]
            }
            var files = working[name] ?? [:]
            let path = op["file_path"]?.stringValue ?? "SKILL.md"
            _ = try Self.file(path, root: directory)
            if action != "create", files["SKILL.md"] == nil { throw HermesLearning.failure("Skill not found. Create it first.") }
            if let review, action != "create" {
                let originalFile = (before[name].flatMap(\.self))?.files[path]
                if let originalFile {
                    guard freshReads[review]?[name + "/" + path].map({ Data($0.utf8) }) == originalFile
                    else { throw HermesLearning.failure("Read the current target file with skill_view during this review before changing it.") }
                }
                if action == "delete" {
                    try backgroundDeleteGuard(name: name, absorbedInto: op["absorbed_into"]?.stringValue, account: account, catalog: catalog)
                }
            }
            if action == "delete", try isPinned(name: name, account: account) {
                throw HermesLearning.failure(
                    "Skill '\(name)' is pinned and cannot be deleted by skill_manage. Ask the user to unpin it in Settings if they want to delete it. Patches and edits are allowed on pinned skills; only deletion is blocked."
                )
            }
            try Self.apply(op, action: action, path: path, files: &files)
            try Self.validate(files, name: name)
            working[name] = files
        }
        // Recheck external editor drift immediately before replacing the package.
        for (name, original) in before {
            let directory = root.appending(path: name)
            let current = FileManager.default.fileExists(atPath: directory.path) ? try Self.package(directory) : nil
            guard current == original else { throw HermesLearning.failure("Skill changed while editing. Read it again and retry.") }
        }
        // Autonomous deletes stay recoverable: upstream archives them instead of removing the package.
        if review != nil, let name = working.first(where: { $0.value.isEmpty })?.key {
            try archive(
                name: name, account: account, root: root, source: curator ? "curator" : "review", thread: thread, review: review,
                authorize: authorize
            )
            let target = operations.first?.objectValue?["absorbed_into"]?.stringValue ?? ""
            return .object(["success": .bool(true), "message": .string("Skill '\(name)' archived. Content absorbed into '\(target)'.")])
        }
        return try save(working, before: before, account: account, root: root, thread: thread, review: review, curator: curator, authorize: authorize)
    }

    private func save(
        _ working: [String: [String: Data]],
        before: [String: AgentSkillSnapshot?],
        account: String,
        root: URL,
        thread: String?,
        review: String?,
        curator: Bool,
        authorize: @Sendable (Database) throws -> Void
    ) throws -> JSONValue {
        var replaced: [String] = []
        do {
            try dbQueue.write { db in
                try authorize(db)
                for name in working.keys.sorted() {
                    let files = working[name]!
                    let original = before[name].flatMap(\.self)
                    if curator { try Self.authorizeCuration(db, name: name, account: account, creating: original == nil) }
                    let updated = AgentSkillSnapshot(
                        files: files,
                        modes: Dictionary(uniqueKeysWithValues: files.keys.map { ($0, original?.modes[$0] ?? 0o644) })
                    )
                    replaced.append(name)
                    try Self.replace(updated, at: root.appending(path: name))
                    let change = try AgentLearningChangeRecord(
                        id: .v7(), accountID: account, kind: "skill", target: name,
                        before: original.map(HermesLearning.json), after: files.isEmpty ? nil : HermesLearning.json(updated), status: "applied",
                        source: curator ? "curator" : review == nil ? "interactive" : "review", threadID: thread, reviewID: review,
                        createdAt: .now
                    )
                    try change.insert(db)
                    if original == nil {
                        // A create starts a new record. Only background passes hand a skill to the Curator.
                        try db.execute(sql: """
                        INSERT INTO agent_skill_states(accountID,name,createdBy,locked,createdAt) VALUES(?,?,?,0,?)
                        ON CONFLICT(accountID,name) DO UPDATE SET createdBy=excluded.createdBy,createdAt=excluded.createdAt,
                        useCount=0,viewCount=0,patchCount=0,lastUsedAt=NULL,lastViewedAt=NULL,lastPatchedAt=NULL,
                        state='active',pinned=0,archivedAt=NULL
                        """, arguments: [account, name, review == nil ? "learn" : "agent", Date()])
                    } else if files.isEmpty {
                        try db.execute(sql: "DELETE FROM agent_skill_states WHERE accountID=? AND name=?", arguments: [account, name])
                    } else {
                        try Self.recordUsage(db, name: name, account: account, columns: ["patchCount"])
                    }
                }
            }
        } catch {
            for name in replaced {
                try Self.replace(before[name].flatMap(\.self) ?? AgentSkillSnapshot(), at: root.appending(path: name))
            }
            throw error
        }
        return .object(["success": .bool(true), "message": .string("Skill operations saved atomically.")])
    }

    private static func apply(_ op: [String: JSONValue], action: String, path: String, files: inout [String: Data]) throws {
        switch action {
        case "create":
            guard files.isEmpty,
                  let content = op["content"]?.stringValue
            else { throw HermesLearning.failure("Skill already exists or create content missing.") }
            files["SKILL.md"] = Data(content.utf8)
        case "patch":
            if let content = op["content"]?.stringValue {
                guard path == "SKILL.md" else { throw HermesLearning.failure("Full rewrite applies only to SKILL.md.") }
                files[path] = Data(content.utf8)
            } else {
                guard let old = op["old_string"]?.stringValue, !old.isEmpty, let new = op["new_string"]?.stringValue,
                      let data = files[path], let content = String(data: data, encoding: .utf8),
                      content.contains(old) else { throw HermesLearning.failure("old_string must match the current file.") }
                let all = op["replace_all"] == .bool(true)
                guard all || content.components(separatedBy: old).count == 2 else { throw HermesLearning.failure("old_string is ambiguous.") }
                files[path] = Data(content.replacingOccurrences(of: old, with: new).utf8)
            }
        case "write_file":
            guard path != "SKILL.md",
                  let text = op["file_content"]?.stringValue
            else { throw HermesLearning.failure("Use patch for SKILL.md; write_file requires file_content.") }
            files[path] = Data(text.utf8)
        case "remove_file":
            guard path != "SKILL.md",
                  files.removeValue(forKey: path) != nil else { throw HermesLearning.failure("Supporting file not found.") }
        case "delete": files = [:]
        default: throw HermesLearning.failure("Use create, patch, write_file, remove_file, or delete.")
        }
    }

    func undo(id: UUID, account: String, root: URL) throws {
        try dbQueue.write { db in
            guard var change = try AgentLearningChangeRecord.fetchOne(db, key: id), change.accountID == account,
                  change.kind == "skill", change.status == "applied",
                  Self.validName(change.target) else { throw HermesLearning.failure("Change not found.") }
            guard try !Self.locked(db, name: change.target, account: account) else { throw HermesLearning.failure("Skill is locked.") }
            let directory = root.appending(path: change.target)
            let current = FileManager.default.fileExists(atPath: directory.path) ? try Self.package(directory) : AgentSkillSnapshot()
            let expected = try change.after.map {
                try JSONDecoder().decode(AgentSkillSnapshot.self, from: Data($0.utf8))
            } ?? AgentSkillSnapshot()
            guard current == expected else { throw HermesLearning.failure("Skill changed since this update; undo would overwrite newer edits.") }
            let original = try change.before.map {
                try JSONDecoder().decode(AgentSkillSnapshot.self, from: Data($0.utf8))
            } ?? AgentSkillSnapshot()
            try Self.validate(original.files, name: change.target)
            do {
                try Self.replace(original, at: directory)
                if change.after == nil, !original.files.isEmpty {
                    try db.execute(
                        sql: "UPDATE agent_skill_states SET state='active',archivedAt=NULL WHERE accountID=? AND name=?",
                        arguments: [account, change.target]
                    )
                }
                change.status = "reverted"
                try change.update(db)
            } catch {
                try Self.replace(current, at: directory)
                throw error
            }
        }
    }

    /// Captures the unlocked account skill before optimization, including supporting files and permissions.
    func editableSnapshot(name: String, account: String, root: URL) throws -> AgentSkillSnapshot {
        let directory = root.appending(path: name)
        guard Self.validName(name), FileManager.default.fileExists(atPath: directory.appending(path: "SKILL.md").path)
        else { throw HermesLearning.failure("Only account skills can be optimized.") }
        guard try !locked(name: name, account: account) else { throw HermesLearning.failure("Skill is locked.") }
        return try Self.package(directory)
    }

    /// Stages an optimized SKILL.md as a pending change. Upstream sends every evolved skill to human review, never a direct commit.
    func proposeOptimization(
        name: String,
        content: String,
        before: AgentSkillSnapshot,
        account: String,
        root: URL,
        runID: String,
        authorize: @Sendable (Database) throws -> Void = { _ in }
    ) throws {
        let current = try editableSnapshot(name: name, account: account, root: root)
        guard current == before else { throw HermesLearning.failure("Skill changed during optimization; optimize it again.") }
        var files = before.files
        files["SKILL.md"] = Data(content.utf8)
        try Self.validate(files, name: name)
        let after = AgentSkillSnapshot(files: files, modes: before.modes)
        try dbQueue.write { db in
            try authorize(db)
            try AgentLearningChangeRecord(
                id: .v7(), accountID: account, kind: "skill", target: name,
                before: HermesLearning.json(before), after: HermesLearning.json(after), status: "pending",
                source: "optimizer", threadID: nil, reviewID: runID, createdAt: .now
            ).insert(db)
        }
    }

    /// Applies or discards a pending change. It applies only while the skill is still what the proposal started from.
    func resolveProposal(id: UUID, account: String, root: URL, approve: Bool) throws {
        try dbQueue.write { db in
            guard var change = try AgentLearningChangeRecord.fetchOne(db, key: id), change.accountID == account,
                  change.kind == "skill", change.status == "pending", Self.validName(change.target),
                  let before = change.before, let after = change.after else { throw HermesLearning.failure("Change not found.") }
            guard approve else {
                change.status = "discarded"
                return try change.update(db)
            }
            guard try !Self.locked(db, name: change.target, account: account) else { throw HermesLearning.failure("Skill is locked.") }
            let directory = root.appending(path: change.target)
            let current = FileManager.default.fileExists(atPath: directory.path) ? try Self.package(directory) : AgentSkillSnapshot()
            guard try current == JSONDecoder().decode(AgentSkillSnapshot.self, from: Data(before.utf8))
            else { throw HermesLearning.failure("Skill changed since this proposal; optimize it again.") }
            let updated = try JSONDecoder().decode(AgentSkillSnapshot.self, from: Data(after.utf8))
            try Self.validate(updated.files, name: change.target)
            try Self.replace(updated, at: directory)
            do {
                try Self.recordUsage(db, name: change.target, account: account, columns: ["patchCount"])
                change.status = "applied"
                try change.update(db)
            } catch {
                try Self.replace(current, at: directory)
                throw error
            }
        }
    }

    func finishReview(_ id: String) { freshReads[id] = nil }
    static func validName(_ value: String) -> Bool {
        value.count <= 64 && value.range(of: "^[a-z0-9][a-z0-9._-]*$", options: .regularExpression) != nil && value != "." && value != ".."
    }

    private static func file(_ path: String, root: URL) throws -> URL {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard path == "SKILL.md" || (parts.count >= 2 && ["references", "templates", "scripts", "assets"].contains(String(parts[0]))),
              !parts.contains(".."), !parts.contains("."),
              !parts.contains("")
        else { throw HermesLearning.failure("Use a relative supporting path under references/, templates/, scripts/, or assets/.") }
        let url = root.appending(path: path)
        guard PiSandbox.realPath(url).hasPrefix(root.path + "/"),
              PiSandbox.realPath(root) == root.path
        else {
            throw HermesLearning.failure("Symbolic links are not supported in managed skills.")
        }
        return url
    }

    private static func read(_ url: URL, root: URL) throws -> String {
        guard PiSandbox.realPath(url).hasPrefix(root.path + "/") else { throw HermesLearning.failure("Skill path escapes its directory.") }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 1_048_576 else { throw HermesLearning.failure("Supporting files are limited to 1 MiB.") }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func linkedFiles(_ directory: URL) throws -> [String: JSONValue] {
        var groups: [String: JSONValue] = [:]
        for group in ["references", "templates", "assets", "scripts"] {
            let base = directory.appending(path: group)
            guard FileManager.default.fileExists(atPath: base.path) else { continue }
            guard PiSandbox.realPath(base) == base.path else { throw HermesLearning.failure("Symbolic skill directories are unsupported.") }
            let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            var paths: [String] = []
            while let url = enumerator?.nextObject() as? URL {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true else { throw HermesLearning.failure("Symbolic skill files are unsupported.") }
                if values.isRegularFile == true { paths.append(String(url.path.dropFirst(directory.path.count + 1))) }
            }
            if !paths.isEmpty { groups[group] = .array(paths.sorted().map(JSONValue.string)) }
        }
        return groups
    }

    static func package(_ directory: URL) throws -> AgentSkillSnapshot {
        guard PiSandbox.realPath(directory) == directory.path else { throw HermesLearning.failure("Symbolic skill directories are unsupported.") }
        let urls = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        var result = AgentSkillSnapshot()
        while let url = urls?.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            guard values.isSymbolicLink != true else { throw HermesLearning.failure("Symbolic links are unsupported in managed skills.") }
            if values.isRegularFile == true {
                let path = String(url.path.dropFirst(directory.path.count + 1))
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 1_048_576 else { throw HermesLearning.failure("Supporting files are limited to 1 MiB.") }
                result.files[path] = try Data(contentsOf: url)
                result.modes[path] = try (FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0o644
            }
        }
        return result
    }

    private static func frontmatter(_ text: String) -> [String]? {
        let lines = text.components(separatedBy: .newlines)
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else { return nil }
        return Array(lines[1 ..< end])
    }

    private static func description(_ text: String) -> String? {
        guard let lines = frontmatter(text), let index = lines.firstIndex(where: { $0.hasPrefix("description:") }) else { return nil }
        let value = String(lines[index].dropFirst(12)).trimmingCharacters(in: .whitespaces)
        if [">", "|", ">-", "|-", ">+", "|+"].contains(value) {
            let continuation = lines.dropFirst(index + 1).prefix { $0.isEmpty || $0.first?.isWhitespace == true }
            return continuation.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
        }
        return value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }

    private static func validate(_ files: [String: Data], name: String) throws {
        guard !files.isEmpty else { return }
        guard let data = files["SKILL.md"], let text = String(data: data, encoding: .utf8), text.hasPrefix("---\n"),
              text.dropFirst(4).contains("\n---"),
              HermesLearning.count(text) <= 100_000, let description = description(text), !description.isEmpty,
              HermesLearning.count(description) <= 1024,
              frontmatter(text)?
              .contains(where: { $0 == "name: \(name)" || $0 == "name: \"\(name)\"" || $0 == "name: '\(name)'" }) == true
        else {
            throw HermesLearning
                .failure("SKILL.md requires matching name and description YAML frontmatter (description ≤1024, content ≤100000 characters).")
        }
        for (path, content) in files {
            if path != "SKILL.md", content.count > 1_048_576 { throw HermesLearning.failure("Supporting file exceeds 1 MiB.") }
            if let text = String(data: content, encoding: .utf8) { try HermesLearning.validate(text) }
        }
    }

    private static func replace(_ snapshot: AgentSkillSnapshot, at directory: URL) throws {
        let files = snapshot.files
        let manager = FileManager.default
        try manager.createDirectory(
            at: directory.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        if files.isEmpty {
            if manager.fileExists(atPath: directory.path) {
                try manager.removeItem(at: directory)
            }
            return
        }
        let staging = directory.deletingLastPathComponent().appending(path: ".skill-\(UUID().uuidString)")
        try manager.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: staging) }
        for (path, content) in files {
            let url = staging.appending(path: path)
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, options: .atomic)
            try manager.setAttributes([.posixPermissions: snapshot.modes[path] ?? 0o644], ofItemAtPath: url.path)
        }
        if manager.fileExists(atPath: directory.path) {
            _ = try manager.replaceItemAt(directory, withItemAt: staging)
        } else {
            try manager.moveItem(at: staging, to: directory)
        }
    }
}
