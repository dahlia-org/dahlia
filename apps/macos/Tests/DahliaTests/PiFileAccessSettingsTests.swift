import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct PiFileAccessSettingsTests {
        @Test(arguments: [PiRuntimeService.LaunchOptions.Mode.chat, .control, .summary, .skills], ["", "/bin"])
        func everyPiModeRejectsCommandSearchInsideWritableSkills(_ mode: PiRuntimeService.LaunchOptions.Mode, _ suffix: String) throws {
            let root = FileManager.default.temporaryDirectory.appending(path: "PiSkillsPath-\(UUID())")
            let agent = root.appending(path: "agent")
            let path = agent.appending(path: "skills").path + suffix
            let launch = PiLaunchSettings(variables: [.init(id: UUID(), name: "PATH", value: path + ":/usr/bin:/bin")])
            #expect(throws: CodexAppServerError.launchFailed(L10n.agentSkillsPathConflict)) {
                try PiRuntimeService.launchEnvironment(
                    .init(mode: mode, cwd: root.appending(path: "work")),
                    provider: .local, agentURL: agent,
                    executableURL: URL(fileURLWithPath: "/usr/bin/true"), launch: launch, secret: { _ in nil }
                )
            }
        }

        @Test
        func skillsPathValidationUsesResolvedSecretPathAndFinalOverrides() throws {
            let root = FileManager.default.temporaryDirectory.appending(path: "PiSkillsPath-\(UUID())")
            let agent = root.appending(path: "agent")
            let skills = agent.appending(path: "skills")
            try FileManager.default.createDirectory(at: skills, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let alias = root.appending(path: "alias")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: skills)
            let launch = PiLaunchSettings(variables: [.init(id: UUID(), name: "PATH", isSecret: true)])
            var options = PiRuntimeService.LaunchOptions(mode: .control, cwd: agent)
            #expect(throws: CodexAppServerError.launchFailed(L10n.agentSkillsPathConflict)) {
                try PiRuntimeService.launchEnvironment(
                    options, provider: .local, agentURL: agent, executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                    launch: launch, secret: { _ in alias.appending(path: "missing/bin").path }
                )
            }
            options.environment["PATH"] = "skills/bin"
            #expect(throws: CodexAppServerError.launchFailed(L10n.agentSkillsPathConflict)) {
                try PiRuntimeService.launchEnvironment(
                    options, provider: .local, agentURL: agent, executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                    launch: launch, secret: { _ in "/usr/bin:/bin" }
                )
            }
        }

        @Test
        func settingsAreLocalToEachAccountAndRemovalPersists() throws {
            let defaults = try #require(UserDefaults(suiteName: "PiFileAccessSettingsTests.\(UUID())"))
            let other = CodexRuntimeProvider(accountConnectionID: .v7(), databricksConnectionID: nil)
            var settings = PiFileAccessSettings(grants: [.init(path: "/Users/test/.desk.toml", isDirectory: false, access: .readWrite)])
            #expect(PiFileAccessSettings.load(for: .local, defaults: defaults).grants.isEmpty)
            settings.save(for: .local, defaults: defaults)
            #expect(PiFileAccessSettings.load(for: .local, defaults: defaults) == settings)
            #expect(PiFileAccessSettings.load(for: other, defaults: defaults).grants.isEmpty)
            settings.grants.removeAll()
            settings.save(for: .local, defaults: defaults)
            #expect(PiFileAccessSettings.load(for: .local, defaults: defaults).grants.isEmpty)
        }

        @Test
        func writeGrantsCannotCoverHomeLibraryOrCommands() throws {
            let home = "/Users/test"
            let searchPath = "/usr/local/bin:/Users/test/.local/bin"
            for path in ["/", home, home + "/Library", "/usr/local", "/usr/local/bin", "/usr/local/bin/tool", home + "/.local"] {
                #expect(throws: (any Error).self) {
                    try PiFileAccessSettings.resolved(.init(path: path, isDirectory: true, access: .readWrite), searchPath: searchPath, home: home)
                }
            }
            for grant in [
                PiFileAccessSettings.Grant(path: home + "/.desk.toml", isDirectory: false, access: .readWrite),
                .init(path: home + "/Documents", isDirectory: true, access: .readWrite),
                .init(path: home, isDirectory: true),
            ] {
                #expect(try PiFileAccessSettings.resolved(grant, searchPath: searchPath, home: home) == grant)
            }
            #expect(throws: (any Error).self) {
                try PiFileAccessSettings.resolved(.init(path: "relative", isDirectory: false), searchPath: searchPath)
            }
        }

        @Test
        func shellStartupFilesCannotBeGrantedWriteAccess() throws {
            let home = "/Users/test"
            for name in [
                ".zshenv",
                ".zprofile",
                ".zshrc",
                ".zlogin",
                ".zlogout",
                ".bashrc",
                ".bash_profile",
                ".bash_login",
                ".bash_logout",
                ".profile",
            ] {
                let grant = PiFileAccessSettings.Grant(path: home + "/" + name, isDirectory: false, access: .readWrite)
                #expect(throws: (any Error).self) {
                    _ = try PiFileAccessSettings.resolved(grant, searchPath: "/usr/bin", home: home)
                }
            }
        }

        @Test
        func configuredStartupLocationsAndSymlinkTargetsStayReadOnly() throws {
            let root = FileManager.default.temporaryDirectory.appending(path: "PiFileAccessSettingsTests-\(UUID())")
            let home = root.appending(path: "home"), work = root.appending(path: "work"), dotfiles = root.appending(path: "dotfiles")
            for folder in [home, work, dotfiles] {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            defer { try? FileManager.default.removeItem(at: root) }
            let target = dotfiles.appending(path: "shell-init")
            try Data("fixture".utf8).write(to: target)
            try FileManager.default.createSymbolicLink(at: home.appending(path: ".zshrc"), withDestinationURL: target)
            let future = dotfiles.appending(path: "future-startup")
            try FileManager.default.createSymbolicLink(at: home.appending(path: ".bashrc"), withDestinationURL: future)
            let environment = [
                "ZDOTDIR": "../zsh",
                "BASH_ENV": "../bash-init",
                "ENV": root.appending(path: "ksh-init").path,
                "XDG_CONFIG_HOME": root.appending(path: "config").path,
            ]
            for (path, directory) in [
                (home.appending(path: ".zshrc").path, false), (target.path, false), (future.path, false), (dotfiles.path, true),
                (root.appending(path: "zsh").path, true), (root.appending(path: "bash-init").path, false),
                (root.appending(path: "ksh-init").path, false), (root.appending(path: "config").path, true),
            ] {
                let readOnly = PiFileAccessSettings.Grant(path: path, isDirectory: directory)
                _ = try PiFileAccessSettings.resolved(readOnly, searchPath: "/usr/bin", home: home.path, cwd: work, environment: environment)
                var writable = readOnly
                writable.access = .readWrite
                #expect(throws: (any Error).self) {
                    _ = try PiFileAccessSettings.resolved(writable, searchPath: "/usr/bin", home: home.path, cwd: work, environment: environment)
                }
            }
            _ = try PiFileAccessSettings.resolved(
                .init(path: home.appending(path: ".desk.toml").path, isDirectory: false, access: .readWrite),
                searchPath: "/usr/bin",
                home: home.path,
                cwd: work,
                environment: environment
            )
        }

        @Test
        func secretStartupDirectoryIsCheckedBeforeSavingWriteAccess() async throws {
            let defaults = try #require(UserDefaults(suiteName: "PiFileAccessSettingsTests.\(UUID())"))
            let folder = FileManager.default.temporaryDirectory.appending(path: "PiFileAccessSettingsTests-\(UUID())")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let variable = PiLaunchSettings.Variable(id: .v7(), name: "ZDOTDIR", isSecret: true)
            PiLaunchSettings(variables: [variable]).save(for: .local, defaults: defaults)
            let key = PiLaunchSettings.secretKey(for: .local, id: variable.id)
            let model = PiFileAccessSettingsModel(account: .local, defaults: defaults, secret: { $0 == key ? folder.path : nil })
            await model.add([folder])
            let grant = try #require(model.settings.grants.first)
            await model.setAccess(.readWrite, for: grant.id)
            #expect(model.errorMessage != nil)
            #expect(PiFileAccessSettings.load(for: .local, defaults: defaults).grants.first?.access == .readOnly)
        }

        @Test
        func secretPathIsCheckedBeforeSavingWriteAccess() async throws {
            let defaults = try #require(UserDefaults(suiteName: "PiFileAccessSettingsTests.\(UUID())"))
            let folder = FileManager.default.temporaryDirectory.appending(path: "PiFileAccessSettingsTests-\(UUID())")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let variable = PiLaunchSettings.Variable(id: .v7(), name: "PATH", isSecret: true)
            PiLaunchSettings(variables: [variable]).save(for: .local, defaults: defaults)
            let key = PiLaunchSettings.secretKey(for: .local, id: variable.id)
            let model = PiFileAccessSettingsModel(account: .local, defaults: defaults, secret: { $0 == key ? folder.path : nil })
            await model.add([folder])
            let grant = try #require(model.settings.grants.first)
            await model.setAccess(.readWrite, for: grant.id)
            #expect(model.errorMessage != nil)
            #expect(PiFileAccessSettings.load(for: .local, defaults: defaults).grants.first?.access == .readOnly)
        }

        @Test
        func anUpdateCannotRestoreAccessRevokedWhileItValidated() async throws {
            let suite = "PiFileAccessSettingsTests.\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            let file = FileManager.default.temporaryDirectory.appending(path: "PiFileAccessSettingsTests-\(UUID()).toml")
            try Data("setting".utf8).write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }
            let grant = PiFileAccessSettings.Grant(path: file.path, isDirectory: false)
            PiFileAccessSettings(grants: [grant]).save(for: .local, defaults: defaults)
            PiLaunchSettings(variables: [.init(id: .v7(), name: "PATH", isSecret: true)]).save(for: .local, defaults: defaults)
            let model = PiFileAccessSettingsModel(account: .local, defaults: defaults, secret: { _ in
                // A newer Settings instance revoked permission while this instance was waiting for Keychain.
                if let current = UserDefaults(suiteName: suite) {
                    PiFileAccessSettings().save(for: .local, defaults: current)
                }
                return nil
            })
            await model.setAccess(.readWrite, for: grant.id)
            #expect(PiFileAccessSettings.load(for: .local, defaults: defaults).grants.isEmpty)
            #expect(model.settings.grants.isEmpty)
            #expect(model.errorMessage != nil)
        }

        @Test
        func removingFromAnOlderModelPreservesNewerSettings() throws {
            let defaults = try #require(UserDefaults(suiteName: "PiFileAccessSettingsTests.\(UUID())"))
            let first = PiFileAccessSettings.Grant(path: "/tmp/first", isDirectory: false)
            let second = PiFileAccessSettings.Grant(path: "/tmp/second", isDirectory: false)
            PiFileAccessSettings(grants: [first]).save(for: .local, defaults: defaults)
            let model = PiFileAccessSettingsModel(account: .local, defaults: defaults)
            PiFileAccessSettings(grants: [first, second]).save(for: .local, defaults: defaults)
            model.remove(first.id)
            #expect(PiFileAccessSettings.load(for: .local, defaults: defaults).grants == [second])
        }

        @Test
        func finalLaunchEnvironmentValidatesSecretPathAndOverridesBeforeStartingChat() throws {
            let root = FileManager.default.temporaryDirectory.appending(path: "PiFileAccessSettingsTests-\(UUID())")
            let work = root.appending(path: "work"), commands = root.appending(path: "commands"), otherCommands = root.appending(path: "other")
            for folder in [work, commands, otherCommands] {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            defer { try? FileManager.default.removeItem(at: root) }
            let variable = PiLaunchSettings.Variable(id: .v7(), name: "PATH", isSecret: true)
            let launch = PiLaunchSettings(variables: [variable])
            let key = PiLaunchSettings.secretKey(for: .local, id: variable.id)
            var pathValue = commands.path
            func environment(_ options: PiRuntimeService.LaunchOptions) throws -> [String: String] {
                try PiRuntimeService.launchEnvironment(
                    options, provider: .local, agentURL: root.appending(path: "agent"), executableURL: URL(fileURLWithPath: "/bin/sh"),
                    launch: launch, secret: { $0 == key ? pathValue : nil }
                )
            }
            var options = PiRuntimeService.LaunchOptions(mode: .chat, cwd: work)
            options.fileAccess = .init(grants: [.init(path: commands.path, isDirectory: true, access: .readWrite)])
            #expect(throws: (any Error).self) { _ = try environment(options) }
            pathValue = "../commands"
            #expect(throws: (any Error).self) { _ = try environment(options) }
            pathValue = commands.path
            options.fileAccess.grants[0].access = .readOnly
            let allowed = try environment(options)
            #expect(allowed["PATH"]?.contains(commands.path) == true)
            #expect(allowed["DAHLIA_PI_SANDBOX"]?.contains("EXTRA_0=") == true)
            #expect(allowed["DAHLIA_PI_SANDBOX_HIDDEN_ENV"] == #"["PATH"]"#)
            options.environment["PATH"] = otherCommands.path
            options.fileAccess = .init(grants: [.init(path: otherCommands.path, isDirectory: true, access: .readWrite)])
            #expect(throws: (any Error).self) { _ = try environment(options) }
            // The same final PATH also protects the working directory, independently of additional grants.
            options = .init(mode: .chat, cwd: commands)
            #expect(throws: (any Error).self) { _ = try environment(options) }
            options = .init(mode: .chat, cwd: work, environment: ["BASH_ENV": "$HOME/startup"])
            #expect(throws: CodexAppServerError.launchFailed(L10n.agentShellStartupPathRequired)) { _ = try environment(options) }
            options = .init(mode: .chat, cwd: work, environment: ["ZDOTDIR": work.path])
            #expect(throws: (any Error).self) { _ = try environment(options) }
            options = .init(mode: .chat, cwd: work, environment: ["BASH_ENV": otherCommands.appending(path: "startup").path])
            options.fileAccess = .init(grants: [.init(path: otherCommands.path, isDirectory: true, access: .readWrite)])
            #expect(throws: (any Error).self) { _ = try environment(options) }
            for mode in [PiRuntimeService.LaunchOptions.Mode.summary, .control] {
                options.mode = mode
                #expect(try environment(options)["DAHLIA_PI_SANDBOX"] == nil)
            }
        }

        @Test
        func selectionDefaultsToReadOnlyAndEditsAndRevocationAreSaved() async throws {
            let defaults = try #require(UserDefaults(suiteName: "PiFileAccessSettingsTests.\(UUID())"))
            let file = FileManager.default.temporaryDirectory.appending(path: "PiFileAccessSettingsTests-\(UUID()).toml")
            try Data("setting".utf8).write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }
            let model = PiFileAccessSettingsModel(account: .local, defaults: defaults)
            await model.add([file, file])
            #expect(model.errorMessage == nil)
            #expect(model.settings.grants.count == 1)
            let grant = try #require(model.settings.grants.first)
            #expect(grant.access == .readOnly && !grant.isDirectory)
            await model.setAccess(.readWrite, for: grant.id)
            #expect(model.settings.grants.first?.access == .readWrite)
            #expect(PiFileAccessSettings.load(for: .local, defaults: defaults) == model.settings)
            await model.add([URL(fileURLWithPath: NSHomeDirectory())])
            let home = try #require(model.settings.grants.last)
            await model.setAccess(.readWrite, for: home.id)
            #expect(model.errorMessage != nil)
            #expect(model.settings.grants.last?.access == .readOnly)
            model.remove(grant.id)
            model.remove(home.id)
            #expect(PiFileAccessSettings.load(for: .local, defaults: defaults).grants.isEmpty)
        }
    }
#endif
