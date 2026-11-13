import DahliaMeetingAccess
import DahliaRuntimeSupport
import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct PiSandboxTests {
        @Test
        func defaultAccessGroupsKeepDahliaDataLimitedToImagesAndDatabaseFiles() throws {
            let work = URL(fileURLWithPath: "/example/work")
            let agent = URL(fileURLWithPath: "/example/accounts/local/pi")
            let access = PiSandbox.defaultFileAccess(cwd: work, agentURL: agent)
            #expect(access.resources.contains { $0.path == work.path && $0.access == .readWrite })
            #expect(access.resources.contains { $0.path == agent.appending(path: "skills").path && $0.access == .readWrite })
            let directories = access.data.filter(\.isDirectory)
            #expect(directories.count == 1)
            #expect(directories.first?.path == PiSandbox.realPath(ScreenshotFileStore.defaultDirectory))
            #expect(access.data.filter { !$0.isDirectory }.map { URL(fileURLWithPath: $0.path).lastPathComponent }.sorted() == [
                "dahlia.sqlite", "dahlia.sqlite-shm", "dahlia.sqlite-wal",
            ])
            #expect(access.data.allSatisfy { $0.access == .readOnly })
            #expect(access.system.contains { $0.path == "/System" })
            #expect(access.system.allSatisfy { $0.isDirectory && $0.access == .readOnly })
        }

        @Test(arguments: ["skills", "skills/bin", "skills/missing/bin"])
        func sandboxConstructionRejectsSkillsCommandSearchPaths(_ entry: String) {
            let root = FileManager.default.temporaryDirectory.appending(path: "PiSandboxSkillsPath-\(UUID())")
            let agent = root.appending(path: "agent")
            #expect(throws: PiRuntimeError.launchFailed(L10n.agentSkillsPathConflict)) {
                try PiSandbox.command(
                    cwd: agent, agentURL: agent, piExecutableURL: URL(fileURLWithPath: "/usr/bin/true"), searchPath: entry
                )
            }
        }

        @Test
        func accountSkillsAreWritableWithoutExposingCredentialsOrOtherAccounts() throws {
            let root = FileManager.default.temporaryDirectory.appending(path: "PiSandboxSkills-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let support = root.appending(path: "support")
            let locator = PiAgentDirectoryLocator(applicationSupportURL: support)
            let agent = try locator.agentURL(for: .local)
            let other = try locator.agentURL(for: .dahlia(connectionID: UUID()))
            let work = root.appending(path: "work")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let skills = agent.appending(path: "skills")
            #expect(try run(
                "mkdir '\(skills.path)/learned' && echo instructions > '\(skills.path)/learned/SKILL.md'",
                cwd: work,
                agent: agent,
                support: support
            ) == 0)
            #expect(try run("cat '\(skills.path)/learned/SKILL.md'", cwd: work, agent: agent, support: support) == 0)
            let startup = skills.appending(path: "startup.sh")
            try Data("true".utf8).write(to: startup)
            #expect(try run("echo changed > '\(startup.path)'", cwd: work, agent: agent, support: support, environment: ["BASH_ENV": startup.path]) !=
                0)
            let executable = skills.appending(path: "runtime/pi")
            try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("runtime".utf8).write(to: executable)
            #expect(try run("echo changed > '\(executable.path)'", cwd: work, agent: agent, support: support, pi: executable) != 0)
            for name in ["auth.json", "settings.json", "models.json", "mcp.json"] {
                let file = agent.appending(path: name)
                try Data("secret".utf8).write(to: file)
                #expect(try run("cat '\(file.path)'", cwd: work, agent: agent, support: support) != 0)
                #expect(try run("echo changed > '\(file.path)'", cwd: work, agent: agent, support: support) != 0)
            }
            try FileManager.default.createSymbolicLink(
                at: skills.appending(path: "credential-link"),
                withDestinationURL: agent.appending(path: "auth.json")
            )
            #expect(try run("cat '\(skills.path)/credential-link'", cwd: work, agent: agent, support: support) != 0)
            #expect(try run("echo changed > '\(skills.path)/credential-link'", cwd: work, agent: agent, support: support) != 0)
            #expect(try run("ln -s '\(agent.path)/auth.json' '\(skills.path)/new-link'", cwd: work, agent: agent, support: support) != 0)
            #expect(try run(
                "ln -s '\(agent.path)/auth.json' moved-link && mv moved-link '\(skills.path)/moved-link'",
                cwd: work,
                agent: agent,
                support: support
            ) != 0)
            #expect(try run("ln '\(agent.path)/auth.json' '\(skills.path)/hard-link'", cwd: work, agent: agent, support: support) != 0)
            #expect(try run("echo changed > '\(other.path)/skills/SKILL.md'", cwd: work, agent: agent, support: support) != 0)
            #expect(try run("rm -r '\(skills.path)/learned'", cwd: work, agent: agent, support: support) == 0)
        }

        @Test
        func installedPackagesAreReadOnlyAndDoNotExposeAccountCredentials() throws {
            let root = FileManager.default.temporaryDirectory.appending(path: "PiSandboxTests-\(UUID())")
            let agent = root.appending(path: "agent")
            for path in ["npm/node_modules/tools/skills", "git/github.com/team/tools/skills"] {
                try FileManager.default.createDirectory(at: agent.appending(path: path), withIntermediateDirectories: true)
                try Data("skill".utf8).write(to: agent.appending(path: path + "/SKILL.md"))
            }
            defer { try? FileManager.default.removeItem(at: root) }
            try Data("secret".utf8).write(to: agent.appending(path: "auth.json"))
            for path in ["npm/node_modules/tools/skills", "git/github.com/team/tools/skills"] {
                let skill = agent.appending(path: path + "/SKILL.md").path
                #expect(try run("cat '\(skill)'", cwd: root, agent: agent) == 0)
                #expect(try run("echo changed > '\(skill)'", cwd: root, agent: agent) != 0)
            }
            let link = agent.appending(path: "npm/credential-link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: agent.appending(path: "auth.json"))
            #expect(try run("cat '\(link.path)'", cwd: root, agent: agent) != 0)
            #expect(try run("cat '\(agent.path)/auth.json'", cwd: root, agent: agent) != 0)
        }

        /// Runs a shell command under the real profile and returns its exit status.
        private func run(
            _ script: String,
            cwd: URL,
            agent: URL,
            support: URL? = nil,
            pi: URL = URL(fileURLWithPath: "/bin/sh"),
            fileAccess: PiFileAccessSettings = .init(),
            environment: [String: String] = [:],
            home: String = NSHomeDirectory()
        ) throws -> Int32 {
            let sandbox = try support.map {
                try PiSandbox.command(
                    cwd: cwd,
                    agentURL: agent,
                    piExecutableURL: pi,
                    applicationSupportURL: $0,
                    fileAccess: fileAccess,
                    environment: environment,
                    home: home
                )
            } ?? PiSandbox.command(cwd: cwd, agentURL: agent, piExecutableURL: pi, fileAccess: fileAccess, environment: environment, home: home)
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
        func additionalFilesAndDirectoriesKeepTheirExactAccessAndCanBeRevoked() throws {
            let root = FileManager.default.temporaryDirectory.appending(path: "PiSandboxTests-\(UUID())")
            let work = root.appending(path: "work"), extra = root.appending(path: "extra")
            let agent = root.appending(path: "agent")
            for folder in [work, extra] {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            defer { try? FileManager.default.removeItem(at: root) }
            // Quotes and parentheses stay data, never Seatbelt source.
            let config = extra.appending(path: ".desk \"(config).toml")
            try Data("setting".utf8).write(to: config)
            try Data("private".utf8).write(to: extra.appending(path: "sibling"))
            let quote = { (path: String) in "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            var access = PiFileAccessSettings(grants: [.init(path: config.path, isDirectory: false)])
            #expect(try run("cat \(quote(config.path))", cwd: work, agent: agent, fileAccess: access) == 0)
            #expect(try run("echo changed > \(quote(config.path))", cwd: work, agent: agent, fileAccess: access) != 0)
            #expect(try run("cat '\(extra.path)/sibling'", cwd: work, agent: agent, fileAccess: access) != 0)
            access.grants[0].access = .readWrite
            #expect(try run("echo changed > \(quote(config.path))", cwd: work, agent: agent, fileAccess: access) == 0)
            #expect(try run("echo no > '\(extra.path)/sibling'", cwd: work, agent: agent, fileAccess: access) != 0)
            access.grants = [.init(path: extra.path, isDirectory: true)]
            #expect(try run("cat '\(extra.path)/sibling'", cwd: work, agent: agent, fileAccess: access) == 0)
            #expect(try run("mkdir '\(extra.path)/child'", cwd: work, agent: agent, fileAccess: access) != 0)
            access.grants[0].access = .readWrite
            #expect(try run("mkdir '\(extra.path)/child' && echo x > '\(extra.path)/child/file'", cwd: work, agent: agent, fileAccess: access) == 0)
            // A symlink in an allowed folder does not extend the grant to its destination.
            let outside = root.appending(path: "outside")
            try Data("private".utf8).write(to: outside)
            try FileManager.default.createSymbolicLink(at: extra.appending(path: "link"), withDestinationURL: outside)
            #expect(try run("cat '\(extra.path)/link'", cwd: work, agent: agent, fileAccess: access) != 0)
            #expect(try run("echo no > '\(extra.path)/link'", cwd: work, agent: agent, fileAccess: access) != 0)
            #expect(try run("cat \(quote(config.path))", cwd: work, agent: agent) != 0)
        }

        @Test
        func shellStartupFilesStayReadOnlyEvenInsideTheWorkingFolder() throws {
            let root = FileManager.default.temporaryDirectory.appending(path: "PiSandboxTests-\(UUID())")
            let home = root.appending(path: "home"), work = root.appending(path: "work"), agent = root.appending(path: "agent")
            for folder in [home, work] {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            defer { try? FileManager.default.removeItem(at: root) }
            let target = work.appending(path: "linked-startup")
            let startup = work.appending(path: ".zshrc")
            for file in [target, startup] {
                try Data("fixture".utf8).write(to: file)
            }
            try FileManager.default.createSymbolicLink(at: home.appending(path: ".profile"), withDestinationURL: target)
            let environment = ["ZDOTDIR": work.path]
            for file in [target, startup] {
                #expect(try run("cat '\(file.path)'", cwd: work, agent: agent, environment: environment, home: home.path) == 0)
                #expect(try run("echo changed > '\(file.path)'", cwd: work, agent: agent, environment: environment, home: home.path) != 0)
                #expect(try run("rm '\(file.path)'", cwd: work, agent: agent, environment: environment, home: home.path) != 0)
            }
            #expect(try run("echo setting > .desk.toml", cwd: work, agent: agent, environment: environment, home: home.path) == 0)
        }

        @Test
        func additionalGrantsCannotOverrideProtectedDataOrRuntimeCode() throws {
            let root = FileManager.default.temporaryDirectory.appending(path: "PiSandboxTests-\(UUID())")
            let work = root.appending(path: "work"), support = root.appending(path: "support")
            let agent = support.appending(path: "agent"), bin = root.appending(path: "bin")
            for folder in [work, agent, bin] {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            defer { try? FileManager.default.removeItem(at: root) }
            let pi = bin.appending(path: "pi")
            try Data("runtime".utf8).write(to: pi)
            try Data("secret".utf8).write(to: agent.appending(path: "auth.json"))
            let access = PiFileAccessSettings(grants: [.init(path: root.path, isDirectory: true, access: .readWrite)])
            #expect(try run("cat '\(agent.path)/auth.json'", cwd: work, agent: agent, support: support, pi: pi, fileAccess: access) != 0)
            #expect(try run("echo no > '\(agent.path)/auth.json'", cwd: work, agent: agent, support: support, pi: pi, fileAccess: access) != 0)
            #expect(try run("echo no > '\(pi.path)'", cwd: work, agent: agent, support: support, pi: pi, fileAccess: access) != 0)
            #expect(try run(
                "echo no > '\(PiSandbox.piTemporaryDirectory.path)/planted'",
                cwd: work,
                agent: agent,
                fileAccess: .init(grants: [.init(path: PiSandbox.piTemporaryDirectory.path, isDirectory: true, access: .readWrite)])
            ) !=
                0)
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
            // Not even when the user works in a folder that contains it.
            let temporary = FileManager.default.temporaryDirectory
            #expect(try run("echo x > '\(PiSandbox.piTemporaryDirectory.path)/planted'", cwd: temporary, agent: agent) != 0)
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
        func piInstalledInsideTheWorkingFolderIsNotWritable() throws {
            let work = FileManager.default.temporaryDirectory.appending(path: "PiSandboxTests-\(UUID())")
            let bin = work.appending(path: "tools/bin")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: work) }
            let pi = bin.appending(path: "pi")
            try Data("#!/bin/sh\n".utf8).write(to: pi)
            let agent = work.appending(path: "none")

            #expect(try run("echo x > in.txt", cwd: work, agent: agent, pi: pi) == 0)
            #expect(try run("echo x >> tools/bin/pi || echo x > tools/bin/node", cwd: work, agent: agent, pi: pi) != 0)
            #expect(try Data(contentsOf: pi) == Data("#!/bin/sh\n".utf8))

            let home = "/Users/u"
            func root(_ path: String) -> String { PiSandbox.installRoot(of: URL(fileURLWithPath: path), home: home) }
            #expect(root("/Users/u/.nvm/versions/node/v24/lib/node_modules/@earendil-works/pi/dist/cli.js") == "/Users/u/.nvm/versions/node/v24")
            // Installed in the home folder itself: the whole `node_modules`, where its dependencies sit beside it.
            #expect(root("/Users/u/node_modules/pi/dist/cli.js") == "/Users/u/node_modules")
            #expect(root("/Users/u/lib/node_modules/pi/dist/cli.js") == "/Users/u/lib/node_modules")

        }

        @Test
        func theWorkingFolderHoldsNothingThatRunsOutsideTheSandbox() throws {
            func allowed(_ path: String) -> Bool { PiWorkingDirectory.isAllowed(path, home: "/Users/u") }
            #expect(allowed("/Users/u/Dahlia") && allowed("/Users/u/Documents/AI") && allowed("/Volumes/Work/Dahlia"))
            // The home folder and its ancestors hold shell profiles and installed tools; Library holds app settings.
            #expect(!allowed("/Users/u") && !allowed("/Users/u/") && !allowed("/Users") && !allowed("/"))
            #expect(!allowed("/Users/u/Library") && !allowed("/Users/u/Library/Application Support/Dahlia"))
            #expect(!allowed("/Users/u/Dahlia/../../u") && !allowed("Dahlia"))

            // A folder that holds commands Dahlia starts outside the sandbox: chat could replace `pi` or shadow `node`.
            let tools = URL(fileURLWithPath: "/usr/local")
            #expect(PiWorkingDirectory.holdsCommands(tools, searchPath: "/opt/x/bin:/usr/local/bin"))
            #expect(PiWorkingDirectory.holdsCommands(tools.appending(path: "bin"), searchPath: "/usr/local/bin"))
            #expect(!PiWorkingDirectory.holdsCommands(tools.appending(path: "share"), searchPath: "/opt/x/bin:/usr/local/bin"))

            // The folder is judged again as the path Seatbelt will see, so a link to a refused folder is refused too.
            let defaults = try #require(UserDefaults(suiteName: "PiSandboxTests.\(UUID())"))
            let link = FileManager.default.temporaryDirectory.appending(path: "PiSandboxTests-\(UUID())")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: NSHomeDirectory()))
            defer { try? FileManager.default.removeItem(at: link) }
            defaults.set(link.path, forKey: PiWorkingDirectory.defaultsKey(for: .local))
            #expect(throws: PiRuntimeError.launchFailed(L10n.agentWorkingDirectoryNotAllowed)) {
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
