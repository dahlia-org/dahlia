import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct PiPackageServiceTests {
        @Test
        func autoReviewAvailabilityFollowsInstalledFilesForAnyPackageRef() throws {
            let agent = FileManager.default.temporaryDirectory.appending(path: "PiAutoReview-\(UUID())")
            defer { try? FileManager.default.removeItem(at: agent) }
            let entry = AgentAutoReviewSettings.entryURL(agentURL: agent)
            try FileManager.default.createDirectory(at: entry.deletingLastPathComponent(), withIntermediateDirectories: true)
            let settings = agent.appending(path: "settings.json")
            try JSONSerialization.data(withJSONObject: ["packages": [AgentAutoReviewSettings.packageSource]]).write(to: settings)
            #expect(!PiPackageService.isAutoReviewInstalled(agentURL: agent))
            try Data().write(to: entry)
            for source in ["https://github.com/mats16/pi-auto-review@b7822c1", AgentAutoReviewSettings.packageSource] {
                try JSONSerialization.data(withJSONObject: ["packages": [source]]).write(to: settings)
                #expect(PiPackageService.isAutoReviewInstalled(agentURL: agent))
            }
            try FileManager.default.removeItem(at: entry)
            #expect(!PiPackageService.isAutoReviewInstalled(agentURL: agent))
        }

        @Test
        func webAccessSettingsDefaultWebSearchOffAndKeepOtherSettings() throws {
            let agent = FileManager.default.temporaryDirectory.appending(path: "PiWebAccess-\(UUID())")
            try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: agent) }
            let url = AgentWebAccessSettings.configURL(agentURL: agent)
            let json = { try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:] }
            try JSONSerialization.data(withJSONObject: [
                "provider": "exa", "braveApiKey": "OLD", "webSearch": ["allowedProviders": ["exa"]],
            ]).write(to: url)

            try AgentWebAccessSettings.writeDefault(agentURL: agent)
            var configuration = try AgentWebAccessSettings.load(agentURL: agent)
            #expect(configuration == .init(webSearchEnabled: false, apiKeys: ["braveApiKey": "OLD"]))
            #expect((try json()["webSearch"] as? [String: Any])?["enabled"] as? Bool == false)

            configuration.webSearchEnabled = true
            configuration.apiKeys = ["braveApiKey": " ", "exaApiKey": " exa-key\n"]
            try AgentWebAccessSettings.save(configuration, agentURL: agent)
            try AgentWebAccessSettings.writeDefault(agentURL: agent)
            let saved = try json()
            #expect(saved["braveApiKey"] == nil && saved["exaApiKey"] as? String == "exa-key" && saved["provider"] as? String == "exa")
            #expect(saved["webSearch"] as? [String: AnyHashable] == ["enabled": true, "allowedProviders": ["exa"]])
            #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int == 0o600)
            #expect(AgentWebAccessSettings.isPackage(AgentWebAccessSettings.packageSource) && !AgentWebAccessSettings.isPackage("npm:pi-web-access-extra"))
        }

        @Test(arguments: [true, false], ["webSearch", "sourceCheck"])
        func webAccessToggleReconcilesToolOverrides(_ enabled: Bool, tool: String) throws {
            let agent = FileManager.default.temporaryDirectory.appending(path: "PiWebAccess-\(UUID())")
            try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: agent) }
            let url = AgentWebAccessSettings.configURL(agentURL: agent)
            var overrides: [String: [String: Any]] = [
                "webSearch": ["enabled": false], "sourceCheck": ["enabled": false], "fetchContent": ["enabled": false],
            ]
            overrides[tool] = ["enabled": enabled, "other": "preserved"]
            try JSONSerialization.data(withJSONObject: [
                "webSearch": ["enabled": !enabled],
                "tools": overrides,
            ]).write(to: url)
            #expect(try AgentWebAccessSettings.load(agentURL: agent).webSearchEnabled == enabled)

            try AgentWebAccessSettings.save(.init(webSearchEnabled: !enabled), agentURL: agent)
            #expect(try AgentWebAccessSettings.load(agentURL: agent).webSearchEnabled == !enabled)
            let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
            let tools = saved?["tools"] as? [String: [String: Any]]
            #expect(tools?["webSearch"]?["enabled"] == nil && tools?["sourceCheck"]?["enabled"] == nil)
            #expect(tools?[tool]?["other"] as? String == "preserved")
            #expect(tools?["fetchContent"]?["enabled"] as? Bool == false)

            try JSONSerialization.data(withJSONObject: ["tools": [tool: ["enabled": true]]]).write(to: url)
            try AgentWebAccessSettings.writeDefault(agentURL: agent)
            #expect(try AgentWebAccessSettings.load(agentURL: agent).webSearchEnabled == false)
            try AgentWebAccessSettings.writeDefault(agentURL: agent)
            #expect(try AgentWebAccessSettings.load(agentURL: agent).webSearchEnabled == false)
        }

        @Test(arguments: ["npm error code ENOVERSIONS", "npm ERR! code ENOVERSIONS"])
        func explainsUnavailableVersionsWithoutDumpingTheCommandLog(_ detail: String) {
            let error = PiPackageService.PackageError.commandFailed(detail + "\nNo versions available for pi-workbuddy-hub")
            #expect(error.errorDescription == L10n.agentPackageNoVersions)
            #expect(error.errorDescription?.contains(detail) == false)
        }

        @Test
        func otherFailuresKeepTheGeneralErrorSummary() {
            let error = PiPackageService.PackageError.commandFailed("npm error code EACCES")
            #expect(error.errorDescription == L10n.agentPackageFailed)
        }

        @Test(arguments: [
            "npm:pi-mcp-adapter", "npm:@example/tools@1.0.0",
            "https://github.com/mats16/ai-desktools", "git:github.com/mats16/ai-desktools@main",
            "ssh://git@example.com/team/tools.git", "git@example.com:team/tools.git",
        ])
        func acceptsPiPackageSources(_ source: String) throws {
            #expect(try PiPackageService.source(" \(source)\n") == source)
        }

        @Test(arguments: [
            ("npm:pi-mcp-adapter", "pi-mcp-adapter"), ("npm:@example/tools@1.0.0", "@example/tools"),
            ("https://github.com/mats16/pi-auto-review@3a12a7d", "pi-auto-review"), ("git:github.com/mats16/ai-desktools@main", "ai-desktools"),
            ("ssh://git@example.com/team/tools.git", "tools"), ("git@example.com:tools.git", "tools"),
        ])
        func namesCardsByPackageOrRepository(_ source: String, _ name: String) {
            #expect(PiPackageService.displayName(source) == name)
        }

        @Test(arguments: ["", "--local", "-l", "pi install npm:tools", "npm:tools\n--local"])
        func rejectsCommandsAndOptions(_ source: String) {
            #expect(throws: PiPackageService.PackageError.self) { try PiPackageService.source(source) }
        }

        @Test
        func readsStringAndFilteredDeclarationsWithoutChangingOtherSettings() throws {
            let root = FileManager.default.temporaryDirectory.appending(path: "PiPackages-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let settings = root.appending(path: "settings.json")
            #expect(try PiPackageService.packageSources(in: settings).isEmpty)
            let data = Data(
                #"{"packages":["npm:tools",{"source":"https://github.com/mats16/ai-desktools","extensions":[]},"npm:tools"],"other":true}"#
                    .utf8
            )
            try data.write(to: settings)
            #expect(try PiPackageService.packageSources(in: settings) == ["https://github.com/mats16/ai-desktools", "npm:tools"])
            #expect(try Data(contentsOf: settings) == data)
            try Data("invalid JSON".utf8).write(to: settings)
            #expect(throws: (any Error).self) { try PiPackageService.packageSources(in: settings) }
        }

        @Test
        func accountsReadOnlyTheirOwnPackageDeclarations() async throws {
            let root = FileManager.default.temporaryDirectory.appending(path: "PiPackages-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let locator = PiAgentDirectoryLocator(applicationSupportURL: root)
            let service = PiPackageService(locator: locator)
            let server = CodexRuntimeProvider.dahlia(connectionID: UUID())
            try Data(#"{"packages":["npm:local-tools"]}"#.utf8)
                .write(to: locator.agentURL(for: .local).appending(path: "settings.json"))
            try Data(#"{"packages":["npm:server-tools"]}"#.utf8)
                .write(to: locator.agentURL(for: server).appending(path: "settings.json"))
            #expect(try await service.packages(for: .local) == ["npm:local-tools"])
            #expect(try await service.packages(for: server) == ["npm:server-tools"])
        }

        @Test
        func packageCommandUsesTheChosenAccountAndCanDownload() throws {
            let directory = URL(fileURLWithPath: "/tmp/package-account")
            let environment = try PiPackageService.environment(
                account: .dahlia(connectionID: UUID()), directory: directory,
                executable: URL(fileURLWithPath: "/opt/homebrew/bin/pi"), launch: .init()
            )
            #expect(environment["PI_CODING_AGENT_DIR"] == directory.path)
            #expect(environment["PI_OFFLINE"] == nil)
            #expect(environment["PI_TELEMETRY"] == "0")
            #expect(environment["GIT_TERMINAL_PROMPT"] == "0")
            #expect(environment["PATH"]?.contains("/opt/homebrew/bin") == true)
        }

        @Test(arguments: ["", "/bin"])
        func packageCommandsRejectCommandSearchInsideWritableSkills(_ suffix: String) {
            let directory = FileManager.default.temporaryDirectory.appending(path: "PiPackageSkillsPath-\(UUID())")
            let path = directory.appending(path: "skills").path + suffix
            let launch = PiLaunchSettings(variables: [.init(id: UUID(), name: "PATH", value: path + ":/usr/bin:/bin")])
            #expect(throws: PiRuntimeError.launchFailed(L10n.agentSkillsPathConflict)) {
                try PiPackageService.environment(
                    account: .local, directory: directory,
                    executable: URL(fileURLWithPath: "/usr/bin/true"), launch: launch
                )
            }
        }

        @Test
        func processGetsLiteralArgumentsAndAccountDirectoryAndReportsFailure() async throws {
            let root = FileManager.default.temporaryDirectory.appending(path: "PiPackages-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let literal = "npm:tools;touch SHOULD_NOT_EXIST"
            try await PiPackageService.run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", #"printf '%s\n%s' "$1" "$PI_CODING_AGENT_DIR" > result"#, "sh", literal],
                environment: ["PI_CODING_AGENT_DIR": root.path], directory: root
            )
            #expect(try String(contentsOf: root.appending(path: "result"), encoding: .utf8) == literal + "\n" + root.path)
            #expect(!FileManager.default.fileExists(atPath: root.appending(path: "SHOULD_NOT_EXIST").path))
            do {
                try await PiPackageService.run(
                    executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo 'installation failed' >&2; exit 7"],
                    environment: [:], directory: root
                )
                Issue.record("Expected a nonzero exit to fail")
            } catch let PiPackageService.PackageError.commandFailed(detail) {
                #expect(detail.contains("installation failed"))
            }
        }
    }
#endif
