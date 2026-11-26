import CryptoKit
import DahliaRuntimeSupport
import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct PiInfrastructureTests {
        @Test
        func presetSkillsAreBundledInAgentSkills() {
            let urls = PiBundle.presetSkillURLs()
            #expect(urls.map(\.lastPathComponent).sorted() == ["meeting-reviewer", "projects-optimizer", "skill-creator", "workspace-backup"])
            for url in urls {
                #expect(url.deletingLastPathComponent().lastPathComponent == "AgentSkills")
                #expect(FileManager.default.fileExists(atPath: url.appending(path: "SKILL.md").path))
            }
        }

        @Test
        func piSelectionUsesManagedInstallationOrAccountPATH() async throws {
            try await Task.detached {
                let suite = "PiInfrastructureTests.\(UUID())"
                let defaults = try #require(UserDefaults(suiteName: suite))
                defer { defaults.removePersistentDomain(forName: suite) }
                let directory = FileManager.default.temporaryDirectory.appending(path: suite)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: directory) }
                let pathPi = directory.appending(path: "pi")
                let managedPi = directory.appending(path: "managed-pi")
                for url in [pathPi, managedPi] {
                    try Data("#!/bin/sh\n".utf8).write(to: url)
                    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
                }
                PiLaunchSettings(variables: [.init(id: UUID(), name: "PATH", value: directory.path)]).save(defaults: defaults)
                #expect(!PiBundle.usesManagedPi(defaults: defaults))
                defaults.set("/old/custom/pi", forKey: "piExecutablePath.\(AppAccount.key)")
                #expect(try PiBundle.executableURL(defaults: defaults, managedExecutableURL: managedPi) == pathPi)
                let key = PiBundle.useManagedPiDefaultsKey()
                defaults.set(true, forKey: key)
                #expect(try PiBundle.executableURL(defaults: defaults, managedExecutableURL: managedPi) == managedPi)

                // Managed mode must fail when missing or a directory, even with a working pi on PATH.
                try FileManager.default.removeItem(at: managedPi)
                #expect(throws: PiRuntimeError.piCommandNotFound(managedPi.path)) {
                    try PiBundle.executableURL(defaults: defaults, managedExecutableURL: managedPi)
                }
                try FileManager.default.createDirectory(at: managedPi, withIntermediateDirectories: true)
                #expect(throws: PiRuntimeError.piCommandNotFound(managedPi.path)) {
                    try PiBundle.executableURL(defaults: defaults, managedExecutableURL: managedPi)
                }
                defaults.set(false, forKey: key)
                #expect(try PiBundle.executableURL(defaults: defaults, managedExecutableURL: managedPi) == pathPi)
            }.value
        }

        @Test
        func piDiscoveryResolvesPathAndNvmSecretsWithoutReadingProviderSecrets() async throws {
            try await Task.detached {
                let suite = "PiInfrastructureTests.\(UUID())"
                let defaults = try #require(UserDefaults(suiteName: suite))
                defer { defaults.removePersistentDomain(forName: suite) }
                let root = FileManager.default.temporaryDirectory.appending(path: suite)
                let nvm = root.appending(path: "custom-nvm")
                let bin = nvm.appending(path: "versions/node/v24.22.1/bin")
                try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: root) }
                let pi = bin.appending(path: "pi")
                try Data("#!/bin/sh\n".utf8).write(to: pi)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pi.path)
                let variables = ["PATH", "NVM_DIR", "OPENAI_API_KEY"].map {
                    PiLaunchSettings.Variable(id: UUID(), name: $0, isSecret: true)
                }
                PiLaunchSettings(variables: variables).save(defaults: defaults)
                let pathKey = PiLaunchSettings.secretKey(id: variables[0].id)
                let nvmKey = PiLaunchSettings.secretKey(id: variables[1].id)
                var requested: [String] = []
                let resolved = try PiBundle.executableURL(defaults: defaults, secret: { key in
                    requested.append(key)
                    return key == pathKey ? bin.path : key == nvmKey ? nvm.path : nil
                })
                #expect(resolved == pi)
                #expect(requested == [pathKey, nvmKey])
            }.value
        }

        @Test
        func legacyPiSelectionPreservesOnlyManagedPathAndExplicitToggleWins() throws {
            let suite = "PiInfrastructureTests.\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let managed = URL(fileURLWithPath: "/test/Dahlia/bin/pi")
            let legacyKey = "piExecutablePath.\(AppAccount.key)"
            for legacy in ["pi", "/custom/bin/pi", "sh", ""] {
                defaults.set(legacy, forKey: legacyKey)
                #expect(!PiBundle.usesManagedPi(defaults: defaults, managedExecutableURL: managed))
            }
            defaults.set(" \(managed.path) ", forKey: legacyKey)
            #expect(PiBundle.usesManagedPi(defaults: defaults, managedExecutableURL: managed))
            defaults.set(false, forKey: PiBundle.useManagedPiDefaultsKey())
            #expect(!PiBundle.usesManagedPi(defaults: defaults, managedExecutableURL: managed))
            defaults.set("/custom/bin/pi", forKey: legacyKey)
            defaults.set(true, forKey: PiBundle.useManagedPiDefaultsKey())
            #expect(PiBundle.usesManagedPi(defaults: defaults, managedExecutableURL: managed))
        }

        @Test
        func managedPiRunsOnItsOwnBun() {
            // `bin/pi` links to a `#!/usr/bin/env node` script, and macOS has no Node.
            let managed = PiInstaller.executableURL
            let command = PiBundle.processCommand(managed, ["--version"], environment: ["PATH": "/usr/bin"])
            #expect(command.executable == PiInstaller.bunURL)
            #expect(command.arguments == [managed.path, "--version"])
            #expect(command.environment == ["PATH": "/usr/bin", "BUN_INSTALL": PiInstaller.directoryURL.path])
            let other = URL(fileURLWithPath: "/opt/homebrew/bin/pi")
            let plain = PiBundle.processCommand(other, ["--version"], environment: [:])
            #expect(plain.executable == other && plain.arguments == ["--version"] && plain.environment.isEmpty)
        }

        @Test
        func installerReplacesPiOnlyWithAPackageThatRuns() async throws {
            // Process and file work runs off the main actor, which every @MainActor suite shares.
            try await Task.detached { try Self.checkInstaller() }.value
        }

        /// A stand-in for Bun: `install` writes Pi's package and its `bin` entry point, whose content is the version, and
        /// running it prints that.
        nonisolated static func fakeBun(in root: URL) throws -> URL {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let url = root.appending(path: "fake-bun")
            try Data(#"""
            #!/bin/sh
            if [ "$1" = install ]; then
              [ -n "$FAIL_INSTALL" ] && exit 1
              version=$(sed -nE 's/.*"@earendil-works\/pi-coding-agent": "([^"]+)".*/\1/p' package.json)
              dir=node_modules/@earendil-works/pi-coding-agent
              mkdir -p "$dir/dist/bundle" && echo "$version" > "$dir/dist/bundle/cli.js" && chmod +x "$dir/dist/bundle/cli.js"
              echo "{\"version\":\"$version\",\"bin\":{\"pi\":\"dist/bundle/cli.js\"}}" > "$dir/package.json"
              exit 0
            fi
            cat "$1"
            """#.utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url
        }

        private nonisolated static func checkInstaller() throws {
            let root = FileManager.default.temporaryDirectory.appending(path: "PiInstallerTests-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let bun = try fakeBun(in: root)
            let environment = ProcessInfo.processInfo.environment
            let directory = root.appending(path: "bun")
            let lock = Data(
                #"{"lockfileVersion":3,"packages":{"":{"version":"0"},"node_modules/a":{"version":"1.0.0","resolved":"https://registry.npmjs.org/a/-/a-1.0.0.tgz","integrity":"sha512-x"}}}"#
                    .utf8
            )
            func install(_ version: String, environment: [String: String] = environment, npmrc: Data = Data("registry=x\n".utf8)) throws {
                let package = Data(#"{"dependencies":{"@earendil-works/pi-coding-agent": "\#(version)"},"overrides":{"b":"2.0.0"}}"#.utf8)
                try PiInstaller.install(
                    version: version, packageJSON: package, packageLock: lock, npmrc: npmrc, bun: bun, environment: environment, into: directory
                )
            }

            try install("1.0.0")
            #expect(PiInstaller.installedVersion(in: directory) == "1.0.0")
            // `bin/pi` links to the package's `bin` entry point, as `bun install -g` links it.
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: directory.appending(path: "bin/pi").path)
                == "../install/global/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js")
            // pi.dev's package.json is installed as published; the lockfile loses only its tarball URLs.
            let global = directory.appending(path: "install/global")
            #expect(try String(contentsOf: global.appending(path: "package.json"), encoding: .utf8).contains(#""overrides":{"b":"2.0.0"}"#))
            let installedLock = try JSONSerialization
                .jsonObject(with: Data(contentsOf: global.appending(path: "package-lock.json"))) as? [String: Any]
            let entry = (installedLock?["packages"] as? [String: [String: String]])?["node_modules/a"]
            #expect(entry == ["version": "1.0.0", "integrity": "sha512-x"])

            // A failed package install or a version that is not a folder name keeps the installed Pi.
            #expect(throws: PiInstallError(stage: .download, reason: .packageInstallFailed)) {
                try install("1.1.0", environment: environment.merging(["FAIL_INSTALL": "1"]) { $1 })
            }
            #expect(throws: PiInstallError.self) { try install("../1.1.0") }
            #expect(PiInstaller.installedVersion(in: directory) == "1.0.0")

            // Installing again replaces Bun's global folder and leaves nothing else behind; the registry setting becomes its
            // `.npmrc`, which `pi update` reads too.
            try install("1.1.0", npmrc: PiInstaller.npmrc(registry: " https://registry.example/ "))
            #expect(PiInstaller.installedVersion(in: directory) == "1.1.0")
            #expect(try String(contentsOf: global.appending(path: ".npmrc"), encoding: .utf8) == "registry=https://registry.example/\n")
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.appending(path: "install").path) == ["global"])

            // Force the final rename to fail after moving the new global folder in; the old package is restored.
            let link = directory.appending(path: "bin/pi")
            let target = try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
            try FileManager.default.removeItem(at: link)
            try FileManager.default.createDirectory(at: link, withIntermediateDirectories: false)
            #expect(throws: PiInstallError(stage: .activation, reason: .fileSystem)) { try install("1.2.0") }
            let restored = try JSONSerialization
                .jsonObject(with: Data(contentsOf: global.appending(path: "node_modules/\(PiInstaller.packageName)/package.json"))) as? [String: Any]
            #expect(restored?["version"] as? String == "1.1.0")
            try FileManager.default.removeItem(at: link)
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target)
            #expect(PiInstaller.installedVersion(in: directory) == "1.1.0")
            try install("1.2.0")
            #expect(PiInstaller.installedVersion(in: directory) == "1.2.0")

            // An install holds the folder's lock against every other open of it, in this process and others, so installs
            // at once (Settings and `--install-pi`) replace the folder one at a time.
            try PiInstaller.withInstallLock(in: directory) {
                let other = open(directory.appending(path: ".lock").path, O_RDWR)
                defer { close(other) }
                #expect(flock(other, LOCK_EX | LOCK_NB) == -1 && errno == EWOULDBLOCK)
            }
            let versions = ["2.0.0", "2.1.0", "2.2.0"]
            DispatchQueue.concurrentPerform(iterations: versions.count) { index in
                try? install(versions[index])
            }
            #expect(versions.contains(PiInstaller.installedVersion(in: directory) ?? ""))
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == [".lock", "bin", "install"])
        }

        @Test
        func registrySettingWritesOnlyAWebURL() throws {
            // Without a setting, Pi installs and updates through the default proxy.
            #expect(try PiInstaller.npmrc(registry: "  ") == Data("registry=https://npm-proxy.cloud.databricks.com/\n".utf8))
            #expect(try PiInstaller.npmrc(registry: "https://registry.npmjs.org") == Data("registry=https://registry.npmjs.org\n".utf8))
            for invalid in ["npm-proxy.cloud.databricks.com", "file:///etc/npmrc", "https://a.example\n//a.example/:_authToken=x", "https://"] {
                #expect(throws: PiInstallError(stage: .download, reason: .invalidRegistry)) { try PiInstaller.npmrc(registry: invalid) }
            }
        }

        @Test
        func piSearchPathStartsWithItsOwnDirectoryForNpmInstalls() {
            let pi = URL(fileURLWithPath: "/Users/me/.nvm/versions/node/v24/bin/pi")
            let path = CommandLineToolLocator.searchPath(
                for: pi,
                environment: ["PATH": "/usr/bin:/Users/me/.nvm/versions/node/v24/bin:/bin"]
            ).split(separator: ":").map(String.init)

            // `#!/usr/bin/env node` resolves the node beside pi even when Finder's launchd PATH lacks it.
            #expect(path.prefix(3) == ["/Users/me/.nvm/versions/node/v24/bin", "/usr/bin", "/bin"])
            #expect(path.contains("/opt/homebrew/bin"))
        }

        @Test
        func registeredMCPServersPersistAndShareTheirWorkspaceSignIn() throws {
            let defaults = try #require(UserDefaults(suiteName: "PiInfrastructureTests.\(UUID())"))
            let workspace = try AgentMCPProvider(workspaceURL: #require(URL(string: "https://example.cloud.databricks.com")))
            #expect(workspace.id == "example.cloud.databricks.com")
            var settings = AgentMCPSettings(providers: [workspace])
            #expect(settings.defaultName(for: "system.ai.slack") == "slack")
            // Any service name becomes a tool-safe server name.
            #expect(settings.defaultName(for: "main.default.My-Tool") == "my_tool")
            settings.servers = [
                AgentMCPServer(id: .v7(), name: "slack", providerID: workspace.id, service: "system.ai.slack"),
                AgentMCPServer(id: .v7(), name: "work_mail", providerID: workspace.id, service: "system.ai.gmail"),
            ]
            settings.save(defaults: defaults)

            #expect(AgentMCPSettings.load(defaults: defaults) == settings)
            // A second Slack gets a numbered name; names are tool prefixes, so they stay unique and tool-safe.
            #expect(settings.defaultName(for: "system.ai.slack") == "slack_2")
            #expect(settings.defaultName(for: "system.ai.slack", taken: ["slack_2"]) == "slack_3")
            #expect(settings.nameError("slack") == L10n.mcpServerNameTaken)
            #expect(settings.nameError("dahlia") == L10n.mcpServerNameTaken)
            #expect(settings.nameError("Slack-1") == L10n.mcpServerNameInvalid)
            #expect(settings.nameError("slack_work") == nil)
            /// Both servers take the workspace's one sign-in; mcp.json itself holds no credential.
            func entry(_ name: String) -> JSONValue {
                .object([
                    "url": .string("https://example.cloud.databricks.com/ai-gateway/mcp-services/system.ai.\(name)"),
                    "exposure": .string("direct"),
                    "auth": .object(["provider": .string(workspace.id)]),
                ])
            }
            #expect(settings.piServers == ["slack": entry("slack"), "work_mail": entry("gmail")])
        }

        @Test
        func processTransportDrainsStderrAndReadsFragmentedJSONLines() async throws {
            let command = "dd if=/dev/zero bs=32768 count=1 >&2 2>/dev/null; "
                + "printf '{\\\"one\\\":1}\\n'; printf '{\\\"two\\\":2}'; printf '\\n'"
            let transport = try CodexAppServerProcessTransport(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", command]
            )

            let first = try #require(await transport.receiveLine())
            let second = try #require(await transport.receiveLine())

            #expect(String(bytes: first, encoding: .utf8) == #"{"one":1}"#)
            #expect(String(bytes: second, encoding: .utf8) == #"{"two":2}"#)
            await transport.close()
        }

        @Test
        func processTransportPassesPrivateAgentDirectory() async throws {
            let expected = "/tmp/dahlia-pi-agent"
            let transport = try CodexAppServerProcessTransport(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf '{\"dir\":\"%s\"}\\n' \"$PI_CODING_AGENT_DIR\""],
                environment: ["PI_CODING_AGENT_DIR": expected]
            )

            let line = try #require(await transport.receiveLine())
            let value = try JSONDecoder().decode(JSONValue.self, from: line)

            #expect(value.objectValue?["dir"]?.stringValue == expected)
            await transport.close()
        }

        @Test(.timeLimit(.minutes(1)))
        func closingAConnectionCancelsItsPendingBridgeAnswer() async {
            // A Databricks token request can be waiting on a browser login; closing Pi must release it.
            let transport = TestPiTransport { _ in [] }
            let (started, startedContinuation) = AsyncStream<Void>.makeStream()
            let (cancelled, cancelledContinuation) = AsyncStream<Void>.makeStream()
            let connection = PiRPCConnection(transport: transport) { _, _ in
                startedContinuation.yield()
                await withTaskCancellationHandler {
                    // Stands in for a browser login that never completes.
                    try? await Task.sleep(for: .seconds(3600))
                } onCancel: {
                    cancelledContinuation.yield()
                }
                throw CancellationError()
            }
            await connection.start()
            await transport.emit(TestPiTransport.bridgeRequest(id: "token-1", method: "token", payload: .object([:])))
            var startedIterator = started.makeAsyncIterator()
            _ = await startedIterator.next()

            await connection.close()

            var cancelledIterator = cancelled.makeAsyncIterator()
            _ = await cancelledIterator.next()
        }

        @Test
        func agentDirectoryIsPrivateAndRemovingADahliaAccountRemovesItsFolders() throws {
            let rootURL = FileManager.default.temporaryDirectory
                .appending(path: "dahlia-pi-agent-test-\(UUID().uuidString)", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: rootURL) }
            let locator = PiAgentDirectoryLocator(applicationSupportURL: rootURL)
            let connectionID = UUID.v7()

            let local = try locator.agentURL()
            let deviceID = try locator.deviceID()

            // The app's one account has one Pi folder, which every agent shares.
            #expect(local == rootURL.appending(path: "Dahlia/pi", directoryHint: .isDirectory))
            let attributes = try FileManager.default.attributesOfItem(atPath: local.path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
            #expect(try locator.deviceID() == deviceID)
            // A Dahlia account that once ran as its own runtime account left these folders.
            let account = rootURL.appending(path: "Dahlia/accounts/\(connectionID.uuidString.lowercased())/pi")
            let legacyHome = rootURL.appending(path: "Dahlia/CodexAccounts/\(connectionID.uuidString.lowercased())")
            for url in [account, legacyHome] {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            }
            try locator.removeAccountDirectory(connectionID: connectionID)
            #expect(!FileManager.default.fileExists(atPath: account.deletingLastPathComponent().path))
            #expect(!FileManager.default.fileExists(atPath: legacyHome.path))
        }

        @Test
        func chatsAreKeptPerWorkspace() throws {
            let rootURL = FileManager.default.temporaryDirectory
                .appending(path: "dahlia-pi-sessions-test-\(UUID().uuidString)", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: rootURL) }
            let locator = PiAgentDirectoryLocator(applicationSupportURL: rootURL)
            let workspaceID = UUID.v7()

            let local = try locator.sessionsURL(workspaceID: workspaceID)

            #expect(local == rootURL.appending(
                path: "Dahlia/pi/sessions/\(workspaceID.uuidString.lowercased())",
                directoryHint: .isDirectory
            ))
            let attributes = try FileManager.default.attributesOfItem(atPath: local.path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        }

        @Test
        func subscriptionModelChoicesPersist() throws {
            let suite = "dahlia-subscription-models-test-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            AgentModelSettings.setModel("openai/gpt-6.1-sol", on: false, defaults: defaults)
            AgentModelSettings.setModel("anthropic/claude-sonnet-4-6", on: true, defaults: defaults)

            let saved = AgentModelSettings.choices(defaults: defaults)
            #expect(!AgentModelSettings.isSubscriptionModelOn("openai/gpt-6.1-sol", choices: saved))
            #expect(AgentModelSettings.isSubscriptionModelOn("anthropic/claude-sonnet-4-6", choices: saved))
            #expect(AgentModelSettings.isSubscriptionModelOn("anthropic/claude-haiku-5-5", choices: saved))
            #expect(!AgentModelSettings.isSubscriptionModelOn("openai/future-model", choices: saved))
        }

        @Test
        func gatewayModelChoicesPersist() throws {
            let suite = "dahlia-agent-models-test-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }

            AgentModelSettings.setModel("databricks/system.ai.gpt-6-luna", on: false, defaults: defaults)
            AgentModelSettings.setModel("dbc-1.cloud.databricks.com/system.ai.gpt-6-luna", on: true, defaults: defaults)

            #expect(AgentModelSettings.choices(defaults: defaults) == [
                "databricks/system.ai.gpt-6-luna": false, "dbc-1.cloud.databricks.com/system.ai.gpt-6-luna": true,
            ])
        }

        @Test
        func modelSelectionPrefersSavedThenFirstAvailable() async {
            let pi = TestPiRuntime { _ in
                TestPiTransport(reply: TestPiRuntime.modelsReply([
                    TestPiTransport.model(provider: "openai", id: "default-model", thinkingLevelMap: .object(["off": .null, "minimal": .null])),
                    TestPiTransport.model(provider: "openai", id: "gpt-6-luna"),
                ]))
            }
            let catalog = CodexModelCatalog(service: pi.service)

            await catalog.load()

            #expect(catalog.resolvedSelection(current: " openai/default-model ") == "openai/default-model")
            #expect(catalog.resolvedSelection(current: "gpt-6-luna") == "openai/gpt-6-luna")
            #expect(catalog.resolvedSelection(current: "missing") == "openai/default-model")
            #expect(catalog.selectionToPersist(current: "missing") == "openai/default-model")
            #expect(catalog.selectionToPersist(current: "") == "openai/default-model")
            #expect(catalog.effortOptions(modelID: "openai/default-model").map(\.reasoningEffort) == ["low", "medium", "high"])
            #expect(catalog.resolvedEffort(current: "", modelID: "openai/default-model") == "medium")
            #expect(catalog.resolvedEffort(current: "high", modelID: "openai/default-model") == "high")
            #expect(catalog.resolvedEffort(current: "max", modelID: "openai/default-model") == "medium")
            #expect(catalog.resolvedEffort(current: "high", modelID: "missing") == nil)
        }

        @Test
        func databricksAndDahliaModelsBecomePiProviders() throws {
            let workspaceURL = try #require(URL(string: "https://example.cloud.databricks.com"))
            let databricks = try PiProviderConfiguration.databricksProviders(
                PiProviderConfiguration.databricksModels(workspaceURL: workspaceURL),
                choices: [:],
                workspaceURL: workspaceURL
            )
            #expect(Set(databricks.keys) == Set(PiProviderConfiguration.databricksProviderIDs))
            let provider = try #require(databricks["databricks"]?.objectValue)
            #expect(provider["baseUrl"] == .string("https://example.cloud.databricks.com"))
            #expect(provider["authHeader"] == .bool(true))
            #expect(provider["apiKey"] == nil)
            // A Databricks account starts with only Haiku on.
            #expect((provider["models"]?.arrayValue ?? []).compactMap { $0.objectValue?["id"]?.stringValue } == ["system.ai.claude-haiku-5-5"])
            // Each model keeps its own gateway route, now on the workspace's host.
            let routes = try Dictionary(
                PiProviderConfiguration.databricksModels(workspaceURL: workspaceURL).map { ($0.id, $0.definition["baseUrl"]?.stringValue ?? "") },
                uniquingKeysWith: { first, _ in first }
            )
            #expect(routes["system.ai.claude-opus-5-5"] == "https://example.cloud.databricks.com/ai-gateway/anthropic")
            #expect(routes["system.ai.gpt-6-luna"] == "https://example.cloud.databricks.com/ai-gateway/codex/v1")
            #expect(routes["system.ai.kimi-k3-1-pro"] == "https://example.cloud.databricks.com/ai-gateway/mlflow/v1")
            #expect(routes["system.ai.gemini-3-8-flash"] == "https://example.cloud.databricks.com/ai-gateway/gemini/v1beta")
            #expect(routes.keys.allSatisfy { !$0.contains("grok") && !$0.contains("deepseek") })

            let catalog = try JSONDecoder().decode(JSONValue.self, from: Data(#"""
            {"data":[{"id":"gpt-6-sol","display_name":"GPT 6 Sol"}],
             "models":[{"slug":"gpt-6-sol","supported_reasoning_levels":[{"effort":"low"},{"effort":"high"}],"input_modalities":["text"]}]}
            """#.utf8))
            let dahlia = try PiProviderConfiguration.dahliaProvider(
                baseURL: #require(URL(string: "https://dahlia.example/api/v1")),
                catalog: catalog
            )
            let model = try #require(dahlia["dahlia"]?.objectValue?["models"]?.arrayValue?.first?.objectValue)
            #expect(model["name"]?.stringValue == "GPT 6 Sol")
            #expect(model["input"] == .array([.string("text")]))
            let converted = try #require(PiProviderConfiguration.codexModel(model.merging(["provider": .string("dahlia")]) { $1 }))
            #expect(converted.supportedReasoningEfforts.map(\.reasoningEffort) == ["low", "high"])
            #expect(!converted.supportsImages)
        }

        @Test
        func databricksGatewayModelsTakeTemplates() throws {
            let services = try JSONDecoder().decode(JSONValue.self, from: Data(#"""
            [
              {"name":"model-services/system.ai.claude-haiku-5-5","supported_api_types":["anthropic/v1/messages"],
               "capabilities":{"function_calling":true,"image_input":true}},
              {"name":"model-services/system.ai.claude-opus-6","supported_api_types":["mlflow/v1/responses","anthropic/v1/messages"],
               "capabilities":{"function_calling":true,"image_input":true}},
              {"name":"model-services/system.ai.claude-opus-5-5","supported_api_types":["anthropic/v1/messages"],
               "capabilities":{"function_calling":true,"image_input":true}},
              {"name":"model-services/system.ai.claude-opus-4-8","supported_api_types":["anthropic/v1/messages"],
               "capabilities":{"function_calling":true,"image_input":true}},
              {"name":"model-services/system.ai.gpt-7-1-luna","supported_api_types":["codex/v1/responses"],
               "capabilities":{"function_calling":true,"image_input":true}},
              {"name":"model-services/system.ai.gpt-7-luna","supported_api_types":["codex/v1/responses"],
               "capabilities":{"function_calling":true,"image_input":true}},
              {"name":"model-services/system.ai.glm-5-3","supported_api_types":["mlflow/v1/responses"],
               "capabilities":{"function_calling":true,"image_input":true}},
              {"name":"model-services/system.ai.glm-6","supported_api_types":["mlflow/v1/responses"],
               "capabilities":{"function_calling":true,"image_input":false}},
              {"name":"model-services/system.ai.gemini-4-argon","supported_api_types":["gemini/v1/generateContent"],
               "capabilities":{"function_calling":true,"image_input":true}},
              {"name":"model-services/system.ai.gemini-4-image","supported_api_types":["gemini/v1/generateContent"],
               "capabilities":{"function_calling":false,"image_input":true}},
              {"name":"model-services/system.ai.gemini-5-flash","supported_api_types":["mlflow/v1/chat/completions"],
               "capabilities":{"function_calling":true,"image_input":true}},
              {"name":"model-services/system.ai.deepseek-v5","supported_api_types":["mlflow/v1/responses"],
               "capabilities":{"function_calling":true,"image_input":true}}
            ]
            """#.utf8)).arrayValue
            let workspaceURL = try #require(URL(string: "https://example.cloud.databricks.com"))
            let gatewayModels = try PiProviderConfiguration.databricksModels(workspaceURL: workspaceURL, services: services)
            let byID = Dictionary(gatewayModels.map { ($0.id, $0.definition) }, uniquingKeysWith: { first, _ in first })

            // Families follow the template order; listed models keep their order, and new ones follow by ID, descending.
            // Models with no template, no route the gateway serves, or no tool calls are not listed.
            #expect(gatewayModels.map(\.id) == [
                "system.ai.claude-opus-5-5", "system.ai.claude-haiku-5-5", "system.ai.claude-opus-6", "system.ai.claude-opus-4-8",
                "system.ai.gpt-7-luna", "system.ai.gpt-7-1-luna",
                "system.ai.glm-5-3", "system.ai.glm-6",
                "system.ai.gemini-4-argon",
            ])
            // Only Haiku starts on; the account's switches decide what `models.json`, and so Pi, lists.
            #expect(gatewayModels.filter(\.isOnByDefault).map(\.id) == ["system.ai.claude-haiku-5-5"])
            let written = PiProviderConfiguration.databricksProviders(
                gatewayModels,
                choices: ["databricks/system.ai.claude-opus-4-8": true, "databricks/system.ai.glm-6": false],
                workspaceURL: workspaceURL
            )
            let writtenIDs = (written["databricks"]?.objectValue?["models"]?.arrayValue ?? []).compactMap { $0.objectValue?["id"]?.stringValue }
            #expect(writtenIDs == ["system.ai.claude-haiku-5-5", "system.ai.claude-opus-4-8"])
            // A new model takes its family's and group's templates, with a generated name and the workspace's route.
            let opus = try #require(byID["system.ai.claude-opus-6"])
            #expect(opus["name"] == .string("Claude Opus 6"))
            #expect(opus["api"] == .string("anthropic-messages"))
            #expect(opus["baseUrl"] == .string("https://example.cloud.databricks.com/ai-gateway/anthropic"))
            #expect(opus["contextWindow"] == .number(1_000_000))
            #expect(opus["cost"]?.objectValue?["input"] == .number(4))
            #expect(opus["match"] == nil && opus["gatewayApi"] == nil && opus["hidden"] == nil)
            let luna = try #require(byID["system.ai.gpt-7-1-luna"])
            #expect(luna["name"] == .string("GPT 7.1 Luna"))
            #expect(luna["thinkingLevelMap"]?.objectValue?["off"] == .string("none"))
            #expect(luna["cost"]?.objectValue?["input"] == .number(0.1))
            // The gateway's image input replaces the template's; a model's own entry replaces both.
            #expect(byID["system.ai.glm-6"]?["input"] == .array([.string("text")]))
            #expect(byID["system.ai.glm-5-3"]?["input"] == .array([.string("text")]))
            #expect(byID["system.ai.gemini-4-argon"]?["reasoning"] == .bool(false))
            #expect(byID["system.ai.gemini-4-argon"]?["cost"]?.objectValue?["input"] == .number(2))
        }

        @Test
        func addedWorkspacesAreModelProvidersBesideTheAccountsOwn() throws {
            let rootURL = FileManager.default.temporaryDirectory.appending(
                path: "dahlia-gateway-test-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: rootURL) }
            let own = try #require(URL(string: "https://own.cloud.databricks.com"))
            let added = try AgentMCPProvider(workspaceURL: #require(URL(string: "https://dbc-1.cloud.databricks.com")))

            let models = try PiProviderConfiguration.databricksModels(workspaceURL: added.workspaceURL, providerID: added.id)
            let opus = try #require(models.first { $0.id == "system.ai.claude-opus-5-5" })
            // Pi and the saved switches name the model by the workspace; pickers tell the gateways apart by its host.
            #expect(opus.reference == "dbc-1.cloud.databricks.com/system.ai.claude-opus-5-5")
            #expect(opus.name == "Claude Opus 5.5")
            #expect(opus.definition["name"] == .string("Claude Opus 5.5 (dbc-1)"))
            #expect(opus.definition["baseUrl"] == .string("https://dbc-1.cloud.databricks.com/ai-gateway/anthropic"))
            // An added workspace starts with every model off, Haiku too.
            #expect(models.allSatisfy { !$0.isOn([:]) })
            #expect(opus.isOn(["dbc-1.cloud.databricks.com/system.ai.claude-opus-5-5": true]))
            #expect(!opus.isOn(["databricks/system.ai.claude-opus-5-5": true]))

            // Each gateway writes its own provider and keeps the others in models.json.
            try PiProviderConfiguration.write(
                PiProviderConfiguration.databricksProviders(
                    PiProviderConfiguration.databricksModels(workspaceURL: own),
                    choices: [:],
                    workspaceURL: own
                ),
                agentURL: rootURL
            )
            try PiProviderConfiguration.write(
                PiProviderConfiguration.databricksProviders(models, choices: [:], workspaceURL: added.workspaceURL, providerID: added.id),
                agentURL: rootURL
            )
            let data = try Data(contentsOf: rootURL.appending(path: "models.json"))
            let providers = try #require(JSONDecoder().decode(JSONValue.self, from: data).objectValue?["providers"]?.objectValue)
            #expect(Set(providers.keys) == ["databricks", "dbc-1.cloud.databricks.com"])
            #expect(providers["dbc-1.cloud.databricks.com"]?.objectValue?["authHeader"] == .bool(true))
        }

        @Test
        func databricksAccountStartsWithAModelEvenWithoutHaiku() throws {
            let services: [JSONValue] = [
                .object([
                    "name": .string("model-services/system.ai.gpt-6-luna"),
                    "supported_api_types": .array([.string("codex/v1/responses")]),
                ]),
                .object([
                    "name": .string("model-services/system.ai.claude-opus-5-5"),
                    "supported_api_types": .array([.string("anthropic/v1/messages")]),
                ]),
            ]
            let workspaceURL = try #require(URL(string: "https://example.cloud.databricks.com"))
            // The gateway serves no Haiku, so its first model starts on; an added workspace still starts with none.
            let own = try PiProviderConfiguration.databricksModels(workspaceURL: workspaceURL, services: services)
            let onByDefault = own.filter(\.isOnByDefault).map(\.id)
            #expect(onByDefault == ["system.ai.claude-opus-5-5"])
            let added = try PiProviderConfiguration.databricksModels(
                workspaceURL: workspaceURL,
                services: services,
                providerID: "example.cloud.databricks.com"
            )
            let addedOn = added.filter(\.isOnByDefault)
            #expect(addedOn.isEmpty)
        }

        @Test
        func aGatewayAnswerWithNoModelKeepsTheSavedList() throws {
            let agentURL = FileManager.default.temporaryDirectory.appending(
                path: "dahlia-gateway-saved-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
            try FileManager.default.createDirectory(at: agentURL, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: agentURL) }
            let haiku: [JSONValue] = [.object([
                "name": .string("model-services/system.ai.claude-haiku-5-5"),
                "supported_api_types": .array([.string("anthropic/v1/messages")]),
            ])]

            try PiProviderConfiguration.saveGatewayServices(haiku, providerID: "databricks", agentURL: agentURL)
            // A sign-in that cannot browse system.ai answers with no model, or only with services no template routes
            // (embeddings); the account keeps the models it had.
            try PiProviderConfiguration.saveGatewayServices([], providerID: "databricks", agentURL: agentURL)
            try PiProviderConfiguration.saveGatewayServices(
                [.object([
                    "name": .string("model-services/system.ai.gte-large-en"),
                    "supported_api_types": .array([.string("mlflow/v1/embeddings")]),
                ])],
                providerID: "databricks",
                agentURL: agentURL
            )
            #expect(PiProviderConfiguration.gatewayServices(agentURL: agentURL) == ["databricks": haiku])
        }

        @Test
        func aServiceThatLeavesOutItsAPITypesServesAnyRoute() throws {
            let services: [JSONValue] = [.object(["name": .string("model-services/system.ai.claude-opus-6")])]
            let models = try PiProviderConfiguration.databricksModels(
                workspaceURL: #require(URL(string: "https://example.cloud.databricks.com")),
                services: services
            )
            #expect(models.map(\.id) == ["system.ai.claude-opus-6"])
        }

        @Test
        func theOwnGatewayKeepsAModelOnWhenTheOneKeptOnLeavesIt() throws {
            let workspaceURL = try #require(URL(string: "https://example.cloud.databricks.com"))
            let service = { (id: String, api: String) in
                JSONValue.object(["name": .string("model-services/system.ai.\(id)"), "supported_api_types": .array([.string(api)])])
            }
            // Opus was kept on and Haiku turned off; then the gateway stops serving Opus.
            let choices = ["databricks/system.ai.claude-opus-5-5": true, "databricks/system.ai.claude-haiku-5-5": false]
            let models = try PiProviderConfiguration.databricksModels(
                workspaceURL: workspaceURL,
                services: [service("claude-haiku-5-5", "anthropic/v1/messages"), service("gpt-6-luna", "codex/v1/responses")]
            )
            let written = PiProviderConfiguration.databricksProviders(models, choices: choices, workspaceURL: workspaceURL)
            let ids = (written["databricks"]?.objectValue?["models"]?.arrayValue ?? []).compactMap { $0.objectValue?["id"]?.stringValue }
            #expect(ids == ["system.ai.claude-haiku-5-5"])
            #expect(PiProviderConfiguration.effectiveChoices(choices, for: models)["databricks/system.ai.claude-haiku-5-5"] == true)
            // An added workspace may keep every model off.
            let added = try PiProviderConfiguration.databricksModels(
                workspaceURL: workspaceURL,
                services: [service("claude-haiku-5-5", "anthropic/v1/messages")],
                providerID: "example.cloud.databricks.com"
            )
            #expect(PiProviderConfiguration.effectiveChoices([:], for: added).isEmpty)
        }

        @Test
        func gatewayModelNamesAreReadable() {
            #expect(PiProviderConfiguration.displayName("claude-sonnet-5-5") == "Claude Sonnet 5.5")
            #expect(PiProviderConfiguration.displayName("kimi-k3-1-pro") == "Kimi K3.1 Pro")
            #expect(PiProviderConfiguration.displayName("glm-5-3-flash") == "GLM 5.3 Flash")
            #expect(PiProviderConfiguration.displayName("gemini-4-argon") == "Gemini 4 Argon")
        }

        @Test
        func emptyCatalogDoesNotReplaceSavedEffort() {
            let catalog = CodexModelCatalog()
            #expect(catalog.resolvedEffort(current: "high", modelID: "missing") == nil)
        }

        @Test
        func cancelledInitialCatalogLoadCanBeRetried() async {
            let log = TestPiTransportLog()
            let pi = TestPiRuntime { _ in
                let transport = TestPiTransport { _ in [] }
                log.append(transport)
                return transport
            }
            let catalog = CodexModelCatalog(service: pi.service)
            let load = Task { await catalog.load(forceRefresh: true) }

            _ = await log.transport(at: 0).command("get_available_models")
            load.cancel()
            await load.value

            #expect(catalog.models.isEmpty)
            #expect(catalog.errorMessage == nil)
            #expect(catalog.canRetry)
        }

        @Test
        func missingInputModalitiesDoNotSilentlyDisableImages() {
            let model = CodexModel(
                id: "model",
                model: "model",
                displayName: "Model",
                description: "",
                hidden: false,
                isDefault: true,
                supportedReasoningEfforts: [],
                defaultReasoningEffort: "medium",
                inputModalities: nil
            )
            #expect(model.supportsImages)
        }
    }
#endif
