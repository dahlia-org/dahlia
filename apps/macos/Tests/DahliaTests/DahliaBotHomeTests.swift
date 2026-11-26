#if canImport(Testing)
    import Foundation
    import Testing
    @testable import Dahlia

    struct DahliaBotHomeTests {
        @Test func dahliaRestoresItsFilesAndNeverOverwritesSoul() throws {
            let root = FileManager.default.temporaryDirectory.appending(path: "DahliaBotHome-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let home = root.appending(path: "bots/dahlia-bot")
            let suite = "DahliaBotHomeTests.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let key = AgentBotSettings.guidanceKey(for: AppAccount.key)
            defaults.set("A 社を最優先にする", forKey: key)

            try DahliaBotHome.ensure(home, instructions: "rules", defaults: defaults)
            // The guidance kept in settings moves to SOUL.md once.
            #expect(DahliaBotHome.soul(home) == "A 社を最優先にする" && defaults.string(forKey: key) == nil)
            let bot = try String(contentsOf: home.appending(path: "bot.json"), encoding: .utf8)
            #expect(bot.contains(#""name" : "Super Agent""#))

            try "tampered".write(to: home.appending(path: "AGENTS.md"), atomically: true, encoding: .utf8)
            try DahliaBotHome.saveSoul(String(repeating: "あ", count: AgentBotSettings.guidanceLimit + 10), home: home)
            defaults.set("never again", forKey: key)
            try DahliaBotHome.ensure(home, instructions: "rules", defaults: defaults)

            #expect(try String(contentsOf: home.appending(path: "AGENTS.md"), encoding: .utf8) == DahliaBotHome.agents("rules"))
            // The bot's ID survives, SOUL.md stays the user's, and only its first 8,000 characters are given.
            #expect(try String(contentsOf: home.appending(path: "bot.json"), encoding: .utf8) == bot)
            #expect(DahliaBotHome.soulFile(home).count == AgentBotSettings.guidanceLimit + 10)
            #expect(DahliaBotHome.soul(home).count == AgentBotSettings.guidanceLimit)

            // A deleted bot.json comes back with a new ID.
            try FileManager.default.removeItem(at: home.appending(path: "bot.json"))
            try DahliaBotHome.ensure(home, instructions: "rules", defaults: defaults)
            #expect(try String(contentsOf: home.appending(path: "bot.json"), encoding: .utf8) != bot)
        }
    }
#endif
