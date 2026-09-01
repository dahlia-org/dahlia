import Foundation
@testable import Dahlia
import DahliaRuntimeSupport

#if canImport(Testing)
    import Testing

    struct CodexAppServerLauncherTests {
        @Test
        func launchesAppServerWithPrivateCodexHomeUserHomeAndPinnedCodeModeHost() async throws {
            let rootURL = URL.temporaryDirectory
                .appending(path: "dahlia-codex-launcher-\(UUID().uuidString)", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: rootURL) }
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

            let executableURL = rootURL.appending(path: "print-working-directory")
            try Data("#!/bin/sh\n/bin/pwd\n/usr/bin/printenv CODEX_HOME\n/usr/bin/printenv HOME\n/usr/bin/printenv CODEX_CODE_MODE_HOST_PATH\n".utf8)
                .write(to: executableURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executableURL.path)

            let homeLocator = ApplicationSupportCodexHomeLocator(applicationSupportURL: rootURL)
            let expectedHomeURL = try homeLocator.homeURL()
            let skillsURL = expectedHomeURL.appending(path: "skills", directoryHint: .isDirectory)
            let installedSkillURLs = BundledCodexPresetSkillInstaller.skillNames.map { skillName in
                skillsURL.appending(path: skillName, directoryHint: .isDirectory)
            }
            let obsoleteSkillName = try #require(BundledCodexPresetSkillInstaller.obsoleteSkillNames.first)
            let obsoleteSkillURL = skillsURL.appending(path: obsoleteSkillName, directoryHint: .isDirectory)
            for installedSkillURL in installedSkillURLs {
                try FileManager.default.createDirectory(
                    at: installedSkillURL.appending(path: "agents", directoryHint: .isDirectory),
                    withIntermediateDirectories: true
                )
                try Data("stale skill".utf8).write(to: installedSkillURL.appending(path: "SKILL.md"))
                try Data("stale metadata".utf8).write(to: installedSkillURL.appending(path: "agents/openai.yaml"))
            }
            try FileManager.default.createDirectory(at: obsoleteSkillURL, withIntermediateDirectories: true)
            try Data("obsolete preset".utf8).write(to: obsoleteSkillURL.appending(path: "SKILL.md"))
            let launcher = BundledCodexAppServerLauncher(
                executableLocator: FixedCodexExecutableLocator(url: executableURL),
                homeLocator: homeLocator
            )

            let transport = try launcher.launch()
            let line = try #require(await transport.receiveLine())
            let workingDirectory = try #require(String(data: line, encoding: .utf8))
            #expect(
                URL(filePath: workingDirectory, directoryHint: .isDirectory).resolvingSymlinksInPath()
                    == expectedHomeURL.resolvingSymlinksInPath()
            )
            let inheritedHome = try #require(ProcessInfo.processInfo.environment["HOME"])
            let expectedCodeModeHostPath = executableURL.deletingLastPathComponent().appending(path: "codex-code-mode-host").path
            try await expectNextLine(from: transport, equals: expectedHomeURL.path)
            try await expectNextLine(from: transport, equals: inheritedHome)
            try await expectNextLine(from: transport, equals: expectedCodeModeHostPath)
            for (skillName, installedSkillURL) in zip(
                BundledCodexPresetSkillInstaller.skillNames,
                installedSkillURLs
            ) {
                let skill = try String(contentsOf: installedSkillURL.appending(path: "SKILL.md"), encoding: .utf8)
                let metadata = try String(
                    contentsOf: installedSkillURL.appending(path: "agents/openai.yaml"),
                    encoding: .utf8
                )
                #expect(skill.contains("name: \(skillName)"))
                #expect(metadata.contains("$\(skillName)"))
                #expect(try permissions(of: installedSkillURL) == 0o700)
                #expect(try permissions(of: installedSkillURL.appending(path: "agents")) == 0o700)
                #expect(try permissions(of: installedSkillURL.appending(path: "SKILL.md")) == 0o600)
                #expect(try permissions(of: installedSkillURL.appending(path: "agents/openai.yaml")) == 0o600)
            }
            #expect(!FileManager.default.fileExists(atPath: obsoleteSkillURL.path))
            await transport.close()
        }

        @Test
        func dahliaLaunchUsesItsPrivateHomeAndScopedBrokerCapability() async throws {
            let rootURL = URL.temporaryDirectory
                .appending(path: "dahlia-codex-account-launcher-\(UUID().uuidString)", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: rootURL) }
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
            let executableURL = rootURL.appending(path: "print-account-environment")
            let capabilityKey = DahliaTokenBrokerProtocol.capabilityEnvironmentKey
            try Data("#!/bin/sh\n/usr/bin/printenv CODEX_HOME\n/usr/bin/printenv \(capabilityKey)\n".utf8)
                .write(to: executableURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executableURL.path)
            let connectionID = UUID.v7()
            let authorization = DahliaTokenBrokerAuthorization()
            let locator = ApplicationSupportCodexHomeLocator(applicationSupportURL: rootURL)
            let launcher = BundledCodexAppServerLauncher(
                executableLocator: FixedCodexExecutableLocator(url: executableURL),
                homeLocator: locator,
                tokenBrokerAuthorization: authorization,
                runtimeProviderResolver: { .dahlia(connectionID: connectionID) }
            )

            let transport = try launcher.launch()
            try await expectNextLine(
                from: transport,
                equals: locator.homeURL(connectionID: connectionID).path
            )
            let capabilityData = try #require(await transport.receiveLine())
            let capability = try #require(String(data: capabilityData, encoding: .utf8))
            #expect(authorization.matches(
                capability,
                profile: DahliaApplicationSupport.profile(),
                connectionID: connectionID
            ))
            #expect(!authorization.matches(
                capability,
                profile: DahliaApplicationSupport.profile(),
                connectionID: UUID.v7()
            ))
            await transport.close()
        }

        @Test
        func installsEveryPresetSkillWithDistinctContent() throws {
            let rootURL = URL.temporaryDirectory
                .appending(path: "dahlia-codex-skill-set-\(UUID().uuidString)", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: rootURL) }

            let homeURL = try ApplicationSupportCodexHomeLocator(applicationSupportURL: rootURL).homeURL()
            try BundledCodexPresetSkillInstaller().install(into: homeURL)

            let skillsURL = homeURL.appending(path: "skills", directoryHint: .isDirectory)
            var bodies: Set<String> = []
            for skillName in BundledCodexPresetSkillInstaller.skillNames {
                let skillURL = skillsURL
                    .appending(path: skillName, directoryHint: .isDirectory)
                    .appending(path: "SKILL.md")
                let body = try String(contentsOf: skillURL, encoding: .utf8)
                #expect(body.contains("name: \(skillName)"))
                bodies.insert(body)
            }
            #expect(bodies.count == BundledCodexPresetSkillInstaller.skillNames.count)
        }

        @Test
        func projectsOptimizerDefaultsToTheMostRecentNinetyDays() throws {
            let rootURL = URL.temporaryDirectory
                .appending(path: "dahlia-codex-projects-default-\(UUID().uuidString)", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: rootURL) }

            let homeURL = try ApplicationSupportCodexHomeLocator(applicationSupportURL: rootURL).homeURL()
            try BundledCodexPresetSkillInstaller().install(into: homeURL)
            let skillURL = homeURL
                .appending(path: "skills/projects-optimizer/SKILL.md")
            let body = try String(contentsOf: skillURL, encoding: .utf8)

            #expect(body.contains("For a broad request without dates, use the most recent 90 days"))
        }

        @Test
        func replacesSymlinkedPresetWithoutModifyingItsTarget() throws {
            let rootURL = URL.temporaryDirectory
                .appending(path: "dahlia-codex-skill-link-\(UUID().uuidString)", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: rootURL) }

            let homeURL = try ApplicationSupportCodexHomeLocator(applicationSupportURL: rootURL).homeURL()
            let skillsURL = homeURL.appending(path: "skills", directoryHint: .isDirectory)
            let skillName = try #require(BundledCodexPresetSkillInstaller.skillNames.first)
            let installedSkillURL = skillsURL.appending(path: skillName, directoryHint: .isDirectory)
            let externalURL = rootURL.appending(path: "external-skill", directoryHint: .isDirectory)
            let externalSkillURL = externalURL.appending(path: "SKILL.md")
            try FileManager.default.createDirectory(at: skillsURL, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: externalURL, withIntermediateDirectories: true)
            try Data("external skill".utf8).write(to: externalSkillURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: externalURL.path)
            try FileManager.default.createSymbolicLink(at: installedSkillURL, withDestinationURL: externalURL)

            try BundledCodexPresetSkillInstaller().install(into: homeURL)

            #expect(try String(contentsOf: externalSkillURL, encoding: .utf8) == "external skill")
            #expect(try permissions(of: externalURL) == 0o755)
            let values = try installedSkillURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            #expect(values.isDirectory == true)
            #expect(values.isSymbolicLink == false)
        }

        @Test
        func rejectsSymlinkedSkillsDirectoryWithoutModifyingItsTarget() throws {
            let rootURL = URL.temporaryDirectory
                .appending(path: "dahlia-codex-skills-link-\(UUID().uuidString)", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: rootURL) }

            let homeURL = try ApplicationSupportCodexHomeLocator(applicationSupportURL: rootURL).homeURL()
            let skillsURL = homeURL.appending(path: "skills", directoryHint: .isDirectory)
            let externalURL = rootURL.appending(path: "external-skills", directoryHint: .isDirectory)
            let sentinelURL = externalURL.appending(path: "sentinel")
            try FileManager.default.createDirectory(at: externalURL, withIntermediateDirectories: true)
            try Data("preserve".utf8).write(to: sentinelURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: externalURL.path)
            try FileManager.default.createSymbolicLink(at: skillsURL, withDestinationURL: externalURL)

            #expect(throws: CodexAppServerError.self) {
                try BundledCodexPresetSkillInstaller().install(into: homeURL)
            }
            #expect(try String(contentsOf: sentinelURL, encoding: .utf8) == "preserve")
            #expect(try permissions(of: externalURL) == 0o755)
        }
    }

    private struct FixedCodexExecutableLocator: CodexExecutableLocating {
        let url: URL

        func executableURL() throws -> URL {
            url
        }
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require(attributes[.posixPermissions] as? NSNumber).intValue
    }

    private func expectNextLine(from transport: any CodexAppServerTransport, equals expected: String) async throws {
        let line = try #require(await transport.receiveLine())
        #expect(String(data: line, encoding: .utf8) == expected)
    }
#endif
