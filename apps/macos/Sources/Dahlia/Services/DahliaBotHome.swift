import Foundation

/// Super Agent's home folder, as Orca keeps a bot's. Dahlia owns `AGENTS.md` and `bot.json` and rewrites them when they
/// differ; `SOUL.md` is the user's standing guidance, which Dahlia only creates.
enum DahliaBotHome {
    /// The files only Dahlia writes, and `SOUL.md`, which changes only through the user or a `soul_write` they approve.
    nonisolated static let protectedFiles = ["AGENTS.md", "bot.json", "SOUL.md"]

    nonisolated static func agents(_ instructions: String) -> String {
        """
        # Super Agent

        You are Super Agent, the user's secretary in Dahlia. This folder is your home.

        - SOUL.md is the user's standing guidance. It changes only when the user edits it or approves your soul_write.
        - Dahlia writes this file and bot.json; edits to them are replaced.

        \(instructions)

        """
    }

    /// Makes the home what Dahlia expects, so a file changed or removed outside Dahlia is put back.
    nonisolated static func ensure(_ home: URL, instructions: String, defaults: UserDefaults = .standard) throws {
        try PiAgentDirectoryLocator.createPrivateDirectory(home)
        try write(agents(instructions), to: home.appending(path: "AGENTS.md"))
        let botURL = home.appending(path: "bot.json")
        let saved = try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: botURL))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let bot = try encoder.encode(["id": saved?["id"]?.nilIfBlank ?? UUID.v7().uuidString, "name": "Super Agent"])
        try write(String(decoding: bot, as: UTF8.self) + "\n", to: botURL)
        let soulURL = home.appending(path: "SOUL.md")
        if !FileManager.default.fileExists(atPath: soulURL.path) {
            // The guidance kept in settings before the home existed becomes the first SOUL.md.
            let key = AgentBotSettings.guidanceKey(for: AppAccount.key)
            try (defaults.string(forKey: key) ?? "").write(to: soulURL, atomically: true, encoding: .utf8)
            defaults.removeObject(forKey: key)
        }
    }

    /// What Super Agent and the tasks it delegates are given: the start of `SOUL.md`, up to the limit.
    nonisolated static func soul(_ home: URL) -> String {
        String(soulFile(home).prefix(AgentBotSettings.guidanceLimit)).trimmingCharacters(in: .whitespacesAndNewlines)
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
