import DahliaRuntimeSupport
import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct PiSandboxTests {
        /// Runs a shell command under the real profile and returns its exit status.
        private func run(_ script: String, cwd: URL, agent: URL, support: URL? = nil) throws -> Int32 {
            let sandbox = try support.map { try PiSandbox.command(cwd: cwd, agentURL: agent, applicationSupportURL: $0) }
                ?? PiSandbox.command(cwd: cwd, agentURL: agent)
            let command = sandbox + ["/bin/sh", "-c", script]
            let process = Process()
            process.executableURL = URL(fileURLWithPath: command[0])
            process.arguments = Array(command.dropFirst())
            process.currentDirectoryURL = cwd
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }

        @Test
        func aCommandWritesOnlyTheWorkingFolderAndReadsNeitherTheUsersFilesNorPisAgentDirectory() throws {
            let root = FileManager.default.temporaryDirectory.appending(path: "PiSandboxTests-\(UUID())")
            let work = root.appending(path: "work"), agent = root.appending(path: "agent")
            for directory in [work, agent] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            defer { try? FileManager.default.removeItem(at: root) }
            try Data("secret".utf8).write(to: agent.appending(path: "auth.json"))

            #expect(try run("echo x > in.txt && cat in.txt && ls /usr/bin", cwd: work, agent: agent) == 0)
            // Only named system folders are readable: not data other apps and services keep outside the home folder.
            #expect(try run("ls /private/var/tmp || ls /Library/Caches || ls /Library/Preferences", cwd: work, agent: agent) != 0)
            // Pi loads code from its own temporary folder, so a command only reads it.
            #expect(try run("ls '\(PiSandbox.piTemporaryDirectory.path)'", cwd: work, agent: agent) == 0)
            #expect(try run("echo x > '\(PiSandbox.piTemporaryDirectory.path)/planted'", cwd: work, agent: agent) != 0)
            #expect(try run("echo x > ../outside.txt", cwd: work, agent: agent) != 0)
            #expect(!FileManager.default.fileExists(atPath: root.appending(path: "outside.txt").path))
            #expect(try run("ls ~", cwd: work, agent: agent) != 0)
            // Scratch files go to chat's own temporary folder; the user's is neither listed nor written.
            let scratch = PiSandbox.temporaryDirectory.appending(path: "PiSandboxTests-\(UUID())").path
            #expect(try run("echo x > '\(scratch)' && rm '\(scratch)'", cwd: work, agent: agent) == 0)
            #expect(try run("ls '\(FileManager.default.temporaryDirectory.path)'", cwd: work, agent: agent) != 0)
            // A link out of the working folder does not carry a write with it.
            #expect(try run("ln -s ../outside.txt link && echo x > link", cwd: work, agent: agent) != 0)
            #expect(!FileManager.default.fileExists(atPath: root.appending(path: "outside.txt").path))
            // Pi's sign-ins are out of reach even when the agent directory is outside the home folder, as it is here.
            #expect(try run("cat '\(agent.path)/auth.json'", cwd: work, agent: agent) != 0)
            #expect(try run("echo x > '\(agent.path)/mcp.json'", cwd: work, agent: agent) != 0)

            // No Unix socket of another app is reachable.
            let other = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString.prefix(8)).sock")
            defer { try? FileManager.default.removeItem(at: other) }
            let listener = socket(AF_UNIX, SOCK_STREAM, 0)
            defer { close(listener) }
            var address = try DahliaTokenBrokerProtocol.unixAddress(path: other.path)
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(listener, $0, DahliaTokenBrokerProtocol.unixAddressLength(path: other.path))
                }
            }
            #expect(bound == 0 && listen(listener, 1) == 0)
            #expect(try run("/usr/bin/nc -U '\(other.path)' < /dev/null", cwd: work, agent: agent) != 0)
        }

        @Test
        func dahliasOwnDataIsOutOfReachEvenInsideTheWorkingFolder() throws {
            let work = FileManager.default.temporaryDirectory.appending(path: "PiSandboxTests-\(UUID())")
            let support = work.appending(path: "Application Support/Dahlia")
            try FileManager.default.createDirectory(at: support.appending(path: "accounts"), withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: work) }
            let agent = work.appending(path: "none")

            #expect(try run("echo x > in.txt", cwd: work, agent: agent, support: support) == 0)
            #expect(try run("echo x > '\(support.path)/planted'", cwd: work, agent: agent, support: support) != 0)
            // Every account's sign-ins are in there.
            #expect(try run("ls '\(support.path)/accounts'", cwd: work, agent: agent, support: support) != 0)
        }

        @Test
        func theWorkingFolderHoldsNothingThatRunsOutsideTheSandbox() throws {
            func allowed(_ path: String) -> Bool { PiWorkingDirectory.isAllowed(path, home: "/Users/u") }
            #expect(allowed("/Users/u/Dahlia") && allowed("/Users/u/Documents/AI") && allowed("/Volumes/Work/Dahlia"))
            // The home folder and its ancestors hold shell profiles and installed tools; Library holds app settings.
            #expect(!allowed("/Users/u") && !allowed("/Users/u/") && !allowed("/Users") && !allowed("/"))
            #expect(!allowed("/Users/u/Library") && !allowed("/Users/u/Library/Application Support/Dahlia"))
            #expect(!allowed("/Users/u/Dahlia/../../u") && !allowed("Dahlia"))

            // The folder is judged again as the path Seatbelt will see, so a link to a refused folder is refused too.
            let defaults = try #require(UserDefaults(suiteName: "PiSandboxTests.\(UUID())"))
            let link = FileManager.default.temporaryDirectory.appending(path: "PiSandboxTests-\(UUID())")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: NSHomeDirectory()))
            defer { try? FileManager.default.removeItem(at: link) }
            defaults.set(link.path, forKey: PiWorkingDirectory.defaultsKey(for: .local))
            #expect(throws: CodexAppServerError.launchFailed(L10n.agentWorkingDirectoryNotAllowed)) {
                try PiWorkingDirectory().url(for: .local, defaults: defaults)
            }
        }

        @Test
        func anOlderThreadMovesToTheWorkingFolder() throws {
            let file = FileManager.default.temporaryDirectory.appending(path: "PiSandboxTests-\(UUID()).jsonl")
            defer { try? FileManager.default.removeItem(at: file) }
            let rest = #"{"type":"message","id":"a"}"# + "\n"
            try Data((#"{"type":"session","id":"s","cwd":"/old"}"# + "\n" + rest).utf8).write(to: file)
            try PiChatSessionFiles.setWorkingDirectory(URL(fileURLWithPath: "/new"), in: file)
            let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n", maxSplits: 1)
            let header = try JSONDecoder().decode(JSONValue.self, from: Data(lines[0].utf8)).objectValue
            #expect(header?["cwd"]?.stringValue == "/new" && header?["id"]?.stringValue == "s")
            #expect(lines[1] == rest)
        }
    }
#endif
