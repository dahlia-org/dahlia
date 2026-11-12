import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct PiFileAccessSettingsTests {
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
