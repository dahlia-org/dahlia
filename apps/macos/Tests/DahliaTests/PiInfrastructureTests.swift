import CryptoKit
import DahliaRuntimeSupport
import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct PiInfrastructureTests {
        @Test
        func configuredPiCommandIsUsedAndAMissingOneFailsInsteadOfSearching() throws {
            let defaults = try #require(UserDefaults(suiteName: "PiInfrastructureTests.\(UUID())"))
            let directory = FileManager.default.temporaryDirectory.appending(path: "PiInfrastructureTests-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let pi = directory.appending(path: "pi")
            try Data("#!/bin/sh\n".utf8).write(to: pi)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pi.path)

            // Each account keeps its own path.
            let account = CodexRuntimeProvider.databricks(connectionID: UUID())
            defaults.set(" \(pi.path) ", forKey: PiBundle.executablePathDefaultsKey(for: account))
            #expect(try PiBundle.executableURL(for: account, defaults: defaults).path == pi.path)
            #expect((try? PiBundle.executableURL(for: .local, defaults: defaults))?.path != pi.path)

            // A missing file and a directory (which FileManager reports as executable) both fail instead of searching.
            for path in [directory.appending(path: "missing").path, directory.path] {
                defaults.set(path, forKey: PiBundle.executablePathDefaultsKey(for: account))
                #expect(throws: CodexAppServerError.piCommandNotFound(path)) {
                    try PiBundle.executableURL(for: account, defaults: defaults)
                }
            }
        }

        @Test
        func installerReplacesPiOnlyWithAVerifiedArchive() async throws {
            // tar and file work runs off the main actor, which every @MainActor suite shares.
            try await Task.detached { try Self.checkInstaller() }.value
        }

        private nonisolated static func checkInstaller() throws {
            let root = FileManager.default.temporaryDirectory.appending(path: "PiInstallerTests-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            func archive(version: String) throws -> (URL, String) {
                let source = root.appending(path: "source-\(version)/pi")
                try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
                try Data("#!/bin/sh\n".utf8).write(to: source.appending(path: "pi"))
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.appending(path: "pi").path)
                let url = root.appending(path: "pi-\(version).tar.gz")
                let tar = Process()
                tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
                tar.arguments = ["-czf", url.path, "-C", source.deletingLastPathComponent().path, "pi"]
                try tar.run()
                tar.waitUntilExit()
                let digest = try SHA256.hash(data: Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
                return (url, digest)
            }
            let directory = root.appending(path: "Pi")
            let entrypoint = directory.appending(path: "pi")
            func releases() throws -> Set<String> {
                try Set(FileManager.default.contentsOfDirectory(atPath: directory.appending(path: "releases").path))
            }

            let (first, firstDigest) = try archive(version: "1.0.0")
            try PiInstaller.install(archive: first, sha256: firstDigest, version: "1.0.0", into: directory)
            #expect(PiInstaller.installedVersion(in: directory) == "1.0.0")
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: entrypoint.path) == "releases/1.0.0/pi")
            #expect(CommandLineToolLocator.isExecutableFile(atPath: entrypoint.path))

            // A checksum mismatch or a version that is not a folder name keeps the installed Pi.
            let (second, secondDigest) = try archive(version: "1.1.0")
            #expect(throws: PiInstallError.self) {
                try PiInstaller.install(archive: second, sha256: firstDigest, version: "1.1.0", into: directory)
            }
            #expect(throws: PiInstallError.self) {
                try PiInstaller.install(archive: second, sha256: secondDigest, version: "../1.1.0", into: directory)
            }
            #expect(PiInstaller.installedVersion(in: directory) == "1.0.0")

            // The previous release stays for processes still running it; older ones are removed.
            try PiInstaller.install(archive: second, sha256: secondDigest.uppercased(), version: "1.1.0", into: directory)
            #expect(PiInstaller.installedVersion(in: directory) == "1.1.0")
            #expect(try releases() == ["1.0.0", "1.1.0"])
            let (third, thirdDigest) = try archive(version: "1.2.0")
            try PiInstaller.install(archive: third, sha256: thirdDigest, version: "1.2.0", into: directory)
            #expect(try releases() == ["1.1.0", "1.2.0"])

            // Reinstalling the current release keeps the previous one, and a release folder another install already
            // moved in stays in place.
            let marker = directory.appending(path: "releases/1.2.0/marker")
            try Data().write(to: marker)
            try PiInstaller.install(archive: third, sha256: thirdDigest, version: "1.2.0", into: directory)
            #expect(PiInstaller.installedVersion(in: directory) == "1.2.0")
            #expect(try releases() == ["1.1.0", "1.2.0"])
            #expect(FileManager.default.fileExists(atPath: marker.path))

            // An install holds the folder's lock against every other open of it, in this process and others, so installs
            // of different versions at once (Settings and `pi update`) cannot remove the release another just activated.
            try PiInstaller.withInstallLock(in: directory) {
                let other = open(directory.appending(path: ".lock").path, O_RDWR)
                defer { close(other) }
                #expect(flock(other, LOCK_EX | LOCK_NB) == -1 && errno == EWOULDBLOCK)
            }
            let archives = try ["2.0.0", "2.1.0", "2.2.0"].map { version in (version, try archive(version: version)) }
            for _ in 0 ..< 10 {
                DispatchQueue.concurrentPerform(iterations: archives.count) { index in
                    let (version, (url, digest)) = archives[index]
                    try? PiInstaller.install(archive: url, sha256: digest, version: version, into: directory)
                }
                #expect(CommandLineToolLocator.isExecutableFile(atPath: entrypoint.path))
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == [".lock", "pi", "releases"])
        }

        @Test
        func releasesRunByAProcessAreFoundFromTheProcessTable() throws {
            let releases = FileManager.default.temporaryDirectory.appending(path: "PiReleases-\(UUID())")
            try FileManager.default.createDirectory(at: releases.appending(path: "1.0.0"), withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: releases) }
            let real = try #require(realpath(releases.path, nil))
            defer { free(real) }
            let root = String(cString: real)
            // Paths come from the process table as real paths; another folder's executable is not a release.
            #expect(PiInstaller.releasesInUse(in: releases, executablePaths: [
                "\(root)/1.0.0/pi", "\(root)/1.1.0/pi", "\(root)-other/2.0.0/pi", "/usr/bin/true",
            ]) == ["1.0.0", "1.1.0"])
            // The table includes this test process.
            let own = try #require(realpath(CommandLine.arguments[0], nil))
            defer { free(own) }
            #expect(PiInstaller.runningExecutablePaths().contains(String(cString: own)))
        }

        @Test
        func piReleaseDecodesGitHubFields() throws {
            let json = #"{"tag_name":"v1.5.0","assets":[{"name":"pi-darwin-arm64.tar.gz","#
                + #""browser_download_url":"https://github.com/a/b","digest":"sha256:ab"}]}"#
            let release = try JSONDecoder().decode(PiInstaller.Release.self, from: Data(json.utf8))
            #expect(release.version == "1.5.0")
            #expect(release.assets.first?.digest == "sha256:ab")
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
        func gatewayMCPsAreEnabledPerDatabricksAccountAndPointAtTheGateway() throws {
            let defaults = try #require(UserDefaults(suiteName: "PiInfrastructureTests.\(UUID())"))
            let account = UUID()
            let other = UUID()
            defaults.set(true, forKey: DatabricksGatewayMCP.gmail.defaultsKey(connectionID: account))
            defaults.set(true, forKey: DatabricksGatewayMCP.googleCalendar.defaultsKey(connectionID: account))
            defaults.set(true, forKey: DatabricksGatewayMCP.slack.defaultsKey(connectionID: other))

            let enabled = DatabricksGatewayMCP.enabled(connectionID: account, defaults: defaults)
            #expect(enabled == [.gmail, .googleCalendar])
            // Each entry takes the Databricks provider's credential; mcp.json itself holds none.
            func entry(_ name: String) -> JSONValue {
                .object([
                    "url": .string("https://example.cloud.databricks.com/ai-gateway/mcp-services/system.ai.\(name)"),
                    "exposure": .string("direct"),
                    "auth": .object(["provider": .string("databricks")]),
                ])
            }
            #expect(DatabricksGatewayMCP.piServers(enabled, workspaceURL: URL(string: "https://example.cloud.databricks.com")!) == [
                "gmail": entry("gmail"),
                "google_calendar": entry("google_calendar"),
            ])
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
        func closingAConnectionCancelsItsPendingBridgeAnswer() async throws {
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
        func agentDirectoriesArePrivateAndSeparatedByAccount() throws {
            let rootURL = FileManager.default.temporaryDirectory
                .appending(path: "dahlia-pi-agent-test-\(UUID().uuidString)", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: rootURL) }
            let databricksID = UUID.v7()
            let locator = PiAgentDirectoryLocator(applicationSupportURL: rootURL)
            let connectionID = UUID.v7()

            let local = try locator.agentURL(for: .local)
            let account = try locator.agentURL(for: .dahlia(connectionID: connectionID))
            let databricks = try locator.agentURL(for: .databricks(connectionID: databricksID))
            let deviceID = try locator.deviceID()

            #expect(local == rootURL.appending(path: "Dahlia/accounts/local/pi", directoryHint: .isDirectory))
            #expect(databricks == rootURL.appending(
                path: "Dahlia/accounts/\(databricksID.uuidString.lowercased())/pi", directoryHint: .isDirectory
            ))
            #expect(account.path.hasSuffix("accounts/\(connectionID.uuidString.lowercased())/pi"))
            for url in [local, account, databricks] {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
            }
            #expect(try locator.deviceID() == deviceID)
            let legacyHome = rootURL.appending(path: "Dahlia/CodexAccounts/\(connectionID.uuidString.lowercased())")
            try FileManager.default.createDirectory(at: legacyHome, withIntermediateDirectories: true)
            try locator.removeAccountDirectory(connectionID: connectionID)
            #expect(!FileManager.default.fileExists(atPath: account.deletingLastPathComponent().path))
            #expect(!FileManager.default.fileExists(atPath: legacyHome.path))
        }

        @Test
        func chatsBelongToTheAccountThatRanThem() throws {
            let rootURL = FileManager.default.temporaryDirectory
                .appending(path: "dahlia-pi-sessions-test-\(UUID().uuidString)", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: rootURL) }
            let locator = PiAgentDirectoryLocator(applicationSupportURL: rootURL)
            let workspaceID = UUID.v7()
            let databricksID = UUID.v7()

            let local = try locator.sessionsURL(for: .local, workspaceID: workspaceID)
            let databricks = try locator.sessionsURL(for: .databricks(connectionID: databricksID), workspaceID: workspaceID)

            // The same workspace under another account starts with that account's own (empty) history.
            #expect(local == rootURL.appending(path: "Dahlia/accounts/local/pi/sessions/\(workspaceID.uuidString.lowercased())", directoryHint: .isDirectory))
            #expect(databricks.path.hasSuffix("accounts/\(databricksID.uuidString.lowercased())/pi/sessions/\(workspaceID.uuidString.lowercased())"))
            let attributes = try FileManager.default.attributesOfItem(atPath: databricks.path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
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
            let databricks = try PiProviderConfiguration.databricksProviders(
                workspaceURL: #require(URL(string: "https://example.cloud.databricks.com"))
            )
            #expect(Set(databricks.keys) == Set(PiProviderConfiguration.databricksProviderIDs))
            let provider = try #require(databricks["databricks"]?.objectValue)
            #expect(provider["authHeader"] == .bool(true))
            #expect(provider["apiKey"] == nil)
            // Each model keeps its own gateway route, now on the workspace's host.
            let routes = Dictionary(
                (provider["models"]?.arrayValue ?? []).compactMap(\.objectValue).map {
                    ($0["id"]?.stringValue ?? "", $0["baseUrl"]?.stringValue ?? "")
                },
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
