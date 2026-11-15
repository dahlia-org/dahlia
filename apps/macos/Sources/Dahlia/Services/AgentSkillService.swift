import DahliaRuntimeSupport
import Foundation
import GRDB

/// The only app writer of account skills. One actor owns validation, ledger capture and replacement together.
actor AgentSkillService {
    let dbQueue: DatabaseQueue
    private var catalogs: [String: [String: URL]] = [:]
    private var freshReads: [String: [String: String]] = [:]
    init(dbQueue: DatabaseQueue) { self.dbQueue = dbQueue }

    func setCatalog(_ skills: [CodexChatSlashCommand], account: String) {
        catalogs[account] = Dictionary(
            skills.compactMap { skill in skill.skillFileURL.map { (skill.displayName, URL(filePath: PiSandbox.realPath($0))) } },
            uniquingKeysWith: { first, _ in first }
        )
    }

    func locked(name: String, account: String) throws -> Bool {
        try dbQueue.read {
            try Bool.fetchOne(
                $0,
                sql: "SELECT locked FROM agent_skill_states WHERE accountID=? AND name=?",
                arguments: [account, name]
            ) ?? false
        }
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
        authorize: @Sendable (Database) throws -> Void = { _ in }
    ) throws -> JSONValue {
        let args = payload.objectValue ?? [:]
        var catalog = catalogs[account] ?? [:]
        if let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) {
            for name in names where Self.validName(name) {
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
            return try .object([
                "success": .bool(true), "name": .string(name), "description": .string(Self.description(text) ?? ""),
                "content": .string(text), "path": .string(url.path), "skill_dir": .string(file.deletingLastPathComponent().path),
                "linked_files": .object(Self.linkedFiles(file.deletingLastPathComponent())),
                "usage_hint": .string(
                    "To view linked files, call skill_view(name, file_path) where file_path is e.g. 'references/api.md' or 'assets/config.yaml'"
                ),
            ])
        case "skill_manage":
            return try mutate(args, catalog: catalog, account: account, root: root, thread: thread, review: review, authorize: authorize)
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
        var working: [String: [String: String]] = [:]
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
                    guard freshReads[review]?[name + "/" + path] == originalFile
                    else { throw HermesLearning.failure("Read the current target file with skill_view during this review before changing it.") }
                }
                if action == "delete" {
                    let owner = try dbQueue.read {
                        try String.fetchOne(
                            $0,
                            sql: "SELECT createdBy FROM agent_skill_states WHERE accountID=? AND name=?",
                            arguments: [account, name]
                        )
                    }
                    guard owner == "agent" else { throw HermesLearning.failure("Autonomous deletion is limited to agent-created skills.") }
                }
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
        var replaced: [String] = []
        do {
            try dbQueue.write { db in
                try authorize(db)
                for name in working.keys.sorted() {
                    let files = working[name]!
                    let original = before[name].flatMap(\.self)
                    let updated = AgentSkillSnapshot(
                        files: files,
                        modes: Dictionary(uniqueKeysWithValues: files.keys.map { ($0, original?.modes[$0] ?? 0o644) })
                    )
                    replaced.append(name)
                    try Self.replace(updated, at: root.appending(path: name))
                    let change = try AgentLearningChangeRecord(
                        id: .v7(), accountID: account, kind: "skill", target: name,
                        before: original.map(HermesLearning.json), after: files.isEmpty ? nil : HermesLearning.json(updated), status: "applied",
                        source: review == nil ? "interactive" : "review", threadID: thread, reviewID: review, createdAt: .now
                    )
                    try change.insert(db)
                    if original == nil {
                        try db.execute(
                            sql: "INSERT OR IGNORE INTO agent_skill_states(accountID,name,createdBy,locked) VALUES(?,?,'agent',0)",
                            arguments: [account, name]
                        )
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

    private static func apply(_ op: [String: JSONValue], action: String, path: String, files: inout [String: String]) throws {
        switch action {
        case "create":
            guard files.isEmpty,
                  let content = op["content"]?.stringValue
            else { throw HermesLearning.failure("Skill already exists or create content missing.") }
            files["SKILL.md"] = content
        case "patch":
            if let content = op["content"]?.stringValue {
                guard path == "SKILL.md" else { throw HermesLearning.failure("Full rewrite applies only to SKILL.md.") }
                files[path] = content
            } else {
                guard let old = op["old_string"]?.stringValue, !old.isEmpty, let new = op["new_string"]?.stringValue,
                      let content = files[path],
                      content.contains(old) else { throw HermesLearning.failure("old_string must match the current file.") }
                let all = op["replace_all"] == .bool(true)
                guard all || content.components(separatedBy: old).count == 2 else { throw HermesLearning.failure("old_string is ambiguous.") }
                files[path] = content.replacingOccurrences(of: old, with: new)
            }
        case "write_file":
            guard path != "SKILL.md",
                  let text = op["file_content"]?.stringValue
            else { throw HermesLearning.failure("Use patch for SKILL.md; write_file requires file_content.") }
            files[path] = text
        case "remove_file":
            guard path != "SKILL.md",
                  files.removeValue(forKey: path) != nil else { throw HermesLearning.failure("Supporting file not found.") }
        case "delete": files = [:]
        default: throw HermesLearning.failure("Use create, patch, write_file, remove_file, or delete.")
        }
    }

    func undo(id: UUID, account: String, root: URL) throws {
        let changeName = try dbQueue.read {
            try AgentLearningChangeRecord.fetchOne($0, key: id)?.target
        }
        if let changeName, try locked(name: changeName, account: account) { throw HermesLearning.failure("Skill is locked.") }
        try dbQueue.write { db in
            guard var change = try AgentLearningChangeRecord.fetchOne(db, key: id), change.accountID == account,
                  change.kind == "skill", change.status == "applied",
                  Self.validName(change.target) else { throw HermesLearning.failure("Change not found.") }
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
                change.status = "reverted"
                try change.update(db)
            } catch {
                try Self.replace(current, at: directory)
                throw error
            }
        }
    }

    func finishReview(_ id: String) { freshReads[id] = nil }
    private static func validName(_ value: String) -> Bool {
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

    private static func package(_ directory: URL) throws -> AgentSkillSnapshot {
        guard PiSandbox.realPath(directory) == directory.path else { throw HermesLearning.failure("Symbolic skill directories are unsupported.") }
        let urls = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        var result = AgentSkillSnapshot()
        while let url = urls?.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            guard values.isSymbolicLink != true else { throw HermesLearning.failure("Symbolic links are unsupported in managed skills.") }
            if values.isRegularFile == true {
                let path = String(url.path.dropFirst(directory.path.count + 1))
                result.files[path] = try read(url, root: directory)
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

    private static func validate(_ files: [String: String], name: String) throws {
        guard !files.isEmpty else { return }
        guard let text = files["SKILL.md"], text.hasPrefix("---\n"), text.dropFirst(4).contains("\n---"),
              HermesLearning.count(text) <= 100_000, let description = description(text), !description.isEmpty,
              HermesLearning.count(description) <= 1024,
              frontmatter(text)?
              .contains(where: { $0 == "name: \(name)" || $0 == "name: \"\(name)\"" || $0 == "name: '\(name)'" }) == true
        else {
            throw HermesLearning
                .failure("SKILL.md requires matching name and description YAML frontmatter (description ≤1024, content ≤100000 characters).")
        }
        for (path, content) in files {
            if path != "SKILL.md", content.utf8.count > 1_048_576 { throw HermesLearning.failure("Supporting file exceeds 1 MiB.") }
            try HermesLearning.validate(content)
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
            try Data(content.utf8).write(to: url, options: .atomic)
            try manager.setAttributes([.posixPermissions: snapshot.modes[path] ?? 0o644], ofItemAtPath: url.path)
        }
        if manager.fileExists(atPath: directory.path) {
            _ = try manager.replaceItemAt(directory, withItemAt: staging)
        } else {
            try manager.moveItem(at: staging, to: directory)
        }
    }
}
