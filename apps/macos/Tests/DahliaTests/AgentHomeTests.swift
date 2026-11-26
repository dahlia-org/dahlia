#if canImport(Testing)
    import Foundation
    import Testing
    @testable import Dahlia

    struct AgentHomeTests {
        private func agent(_ name: String = "Super Agent") -> AgentRecord {
            AgentRecord(
                id: UUID.v7().uuidString, name: name, directory: "super-agent", avatar: "mascot:E1", color: "#b3dbf4",
                createdAt: .now, updatedAt: .now
            )
        }

        @Test func dahliaRestoresItsCopiesOfTheRowAndNeverOverwritesSoul() throws {
            let root = FileManager.default.temporaryDirectory.appending(path: "AgentHome-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let home = root.appending(path: "agents/super-agent")
            var agent = agent()

            try AgentHome.ensure(home, agent: agent, instructions: "rules")
            #expect(AgentHome.soul(home).isEmpty)
            let json = try String(contentsOf: home.appending(path: "agent.json"), encoding: .utf8)
            let decoded = try JSONDecoder().decode([String: String].self, from: Data(json.utf8))
            #expect(decoded == ["id": agent.id, "name": "Super Agent", "avatar": "mascot:E1", "color": "#b3dbf4"])

            try "tampered".write(to: home.appending(path: "AGENTS.md"), atomically: true, encoding: .utf8)
            try AgentHome.saveSoul(String(repeating: "あ", count: AgentHome.guidanceLimit + 10), home: home)
            try AgentHome.ensure(home, agent: agent, instructions: "rules")
            #expect(try String(contentsOf: home.appending(path: "AGENTS.md"), encoding: .utf8)
                == AgentHome.agents(name: "Super Agent", instructions: "rules"))
            #expect(try String(contentsOf: home.appending(path: "agent.json"), encoding: .utf8) == json)
            // SOUL.md stays the user's, and only its first 8,000 characters are given.
            #expect(AgentHome.soulFile(home).count == AgentHome.guidanceLimit + 10)
            #expect(AgentHome.soul(home).count == AgentHome.guidanceLimit)

            // A rename reaches the copies; the folder stays.
            agent.name = "Secretary"
            try AgentHome.ensure(home, agent: agent, instructions: "rules")
            #expect(try String(contentsOf: home.appending(path: "agent.json"), encoding: .utf8).contains(#""name" : "Secretary""#))
            #expect(try String(contentsOf: home.appending(path: "AGENTS.md"), encoding: .utf8).hasPrefix("# Secretary"))
        }

        @Test(arguments: ["file", "directory", "symlink"])
        func creationNeverAdoptsOrDeletesAnExistingCandidate(kind: String) throws {
            let root = FileManager.default.temporaryDirectory.appending(path: "AgentHome-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let home = root.appending(path: "candidate")
            let preserved: URL
            switch kind {
            case "directory":
                try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
                preserved = home.appending(path: "foreign.txt")
            case "symlink":
                preserved = root.appending(path: "foreign.txt")
                try FileManager.default.createSymbolicLink(at: home, withDestinationURL: preserved)
            default:
                preserved = home
            }
            try "FOREIGN".write(to: preserved, atomically: true, encoding: .utf8)

            #expect(throws: POSIXError.self) {
                try AgentHome.create(home, agent: agent(), instructions: "rules", soul: "new guidance")
            }

            #expect(try String(contentsOf: preserved, encoding: .utf8) == "FOREIGN")
            #expect(FileManager.default.fileExists(atPath: home.path))
            if kind == "symlink" {
                #expect(try FileManager.default.destinationOfSymbolicLink(atPath: home.path) == preserved.path)
            }
        }

        @Test func directoryNamesComeFromTheNameAndNeverCollide() {
            #expect(AgentHome.directoryName(for: "Replies you owe", taken: []) == "replies-you-owe")
            #expect(AgentHome.directoryName(for: "秘書 / 営業:A", taken: []) == "秘書--営業a")
            #expect(AgentHome.directoryName(for: "..hidden", taken: []) == "hidden")
            #expect(AgentHome.directoryName(for: "/", taken: []) == "agent")
            // Folders differing only in case are one folder on the volume.
            #expect(AgentHome.directoryName(for: "Super Agent", taken: ["Super-Agent", "super-agent-2"]) == "super-agent-3")
        }
    }
#endif
