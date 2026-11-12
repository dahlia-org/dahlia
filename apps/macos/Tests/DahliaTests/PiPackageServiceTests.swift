import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct PiPackageServiceTests {
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
        func packageCommandUsesTheChosenAccountAndCanDownload() {
            let directory = URL(fileURLWithPath: "/tmp/package-account")
            let environment = PiPackageService.environment(
                account: .dahlia(connectionID: UUID()), directory: directory,
                executable: URL(fileURLWithPath: "/opt/homebrew/bin/pi")
            )
            #expect(environment["PI_CODING_AGENT_DIR"] == directory.path)
            #expect(environment["PI_OFFLINE"] == nil)
            #expect(environment["PI_TELEMETRY"] == "0")
            #expect(environment["GIT_TERMINAL_PROMPT"] == "0")
            #expect(environment["PATH"]?.contains("/opt/homebrew/bin") == true)
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
