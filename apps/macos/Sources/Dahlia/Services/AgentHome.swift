import Foundation

/// An agent's home folder, as Orca keeps a bot's. Dahlia owns `AGENTS.md` and `agent.json`, copies of the agent's row,
/// and rewrites them when they differ; `SOUL.md` is the user's standing guidance, which Dahlia only creates.
enum AgentHome {
    /// The files only Dahlia writes, and `SOUL.md`, which changes only through the user or a `soul_write` they approve.
    nonisolated static let protectedFiles = ["AGENTS.md", "agent.json", "SOUL.md"]
    /// How much of `SOUL.md` an agent is given.
    nonisolated static let guidanceLimit = 8000

    nonisolated static func agents(name: String, instructions: String) -> String {
        """
        # \(name)

        You are \(name), one of the user's agents in Dahlia. This folder is your home.

        - SOUL.md is the user's standing guidance. It changes only when the user edits it or approves your soul_write.
        - Dahlia writes this file and agent.json; edits to them are replaced.

        \(instructions)

        """
    }

    /// A new agent's folder name: its name as one safe path component, unlike every name in `taken` (compared without
    /// case, as the volume does).
    nonisolated static func directoryName(for name: String, taken: Set<String>) -> String {
        let cleaned = name.lowercased().unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) && !"/:".unicodeScalars.contains($0) }
            .map { CharacterSet.whitespacesAndNewlines.contains($0) ? "-" : String($0) }
            .joined()
        let base = String(cleaned.drop { $0 == "." }.prefix(64)).nilIfBlank ?? "agent"
        let used = Set(taken.map { $0.lowercased() })
        guard used.contains(base) else { return base }
        return (2...).lazy.map { "\(base)-\($0)" }.first { !used.contains($0) }!
    }

    /// A creation attempt owns this leaf only after mkdir succeeds; an existing file, directory, or symlink is never adopted.
    nonisolated static func create(_ home: URL, agent: AgentRecord, instructions: String, soul: String) throws {
        guard mkdir(home.path, 0o700) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        do {
            try ensure(home, agent: agent, instructions: instructions)
            try saveSoul(soul, home: home)
        } catch {
            try? FileManager.default.removeItem(at: home)
            throw error
        }
    }

    /// Makes the home what Dahlia expects, so a file changed or removed outside Dahlia is put back.
    nonisolated static func ensure(_ home: URL, agent: AgentRecord, instructions: String) throws {
        try PiAgentDirectoryLocator.createPrivateDirectory(home)
        try write(agents(name: agent.name, instructions: instructions), to: home.appending(path: "AGENTS.md"))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let json = try encoder.encode(["id": agent.id, "name": agent.name, "avatar": agent.avatar, "color": agent.color])
        try write(String(decoding: json, as: UTF8.self) + "\n", to: home.appending(path: "agent.json"))
        let soulURL = home.appending(path: "SOUL.md")
        if !FileManager.default.fileExists(atPath: soulURL.path) { try "".write(to: soulURL, atomically: true, encoding: .utf8) }
    }

    /// What an agent and the tasks it delegates are given: the start of `SOUL.md`, up to the limit.
    nonisolated static func soul(_ home: URL) -> String {
        String(soulFile(home).prefix(guidanceLimit)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The whole file, for editing: saving must not cut what lies past the limit.
    nonisolated static func soulFile(_ home: URL) -> String {
        (try? String(contentsOf: home.appending(path: "SOUL.md"), encoding: .utf8)) ?? ""
    }

    nonisolated static func saveSoul(_ text: String, home: URL) throws {
        try PiAgentDirectoryLocator.createPrivateDirectory(home)
        try text.write(to: home.appending(path: "SOUL.md"), atomically: true, encoding: .utf8)
    }

    private nonisolated static func write(_ text: String, to url: URL) throws {
        guard (try? String(contentsOf: url, encoding: .utf8)) != text else { return }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}
