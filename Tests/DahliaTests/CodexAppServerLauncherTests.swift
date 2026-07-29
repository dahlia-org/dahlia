import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct CodexAppServerLauncherTests {
        @Test
        func launchesAppServerFromPrivateCodexHome() async throws {
            let rootURL = URL.temporaryDirectory
                .appending(path: "dahlia-codex-launcher-\(UUID().uuidString)", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: rootURL) }
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

            let executableURL = rootURL.appending(path: "print-working-directory")
            try Data("#!/bin/sh\n/bin/pwd\n/usr/bin/printenv HOME\n".utf8).write(to: executableURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executableURL.path)

            let homeLocator = ApplicationSupportCodexHomeLocator(applicationSupportURL: rootURL)
            let expectedHomeURL = try homeLocator.homeURL()
            let installedSkillURL = expectedHomeURL
                .appending(path: "skills", directoryHint: .isDirectory)
                .appending(path: BundledCodexPresetSkillInstaller.skillName, directoryHint: .isDirectory)
            let obsoleteSkillURL = expectedHomeURL
                .appending(path: "skills", directoryHint: .isDirectory)
                .appending(
                    path: BundledCodexPresetSkillInstaller.obsoleteSkillName,
                    directoryHint: .isDirectory
                )
            try FileManager.default.createDirectory(
                at: installedSkillURL.appending(path: "agents", directoryHint: .isDirectory),
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(at: obsoleteSkillURL, withIntermediateDirectories: true)
            try Data("stale skill".utf8).write(to: installedSkillURL.appending(path: "SKILL.md"))
            try Data("stale metadata".utf8).write(to: installedSkillURL.appending(path: "agents/openai.yaml"))
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
            let homeEnvironment = try #require(await transport.receiveLine())
            #expect(String(data: homeEnvironment, encoding: .utf8) == expectedHomeURL.path)
            let skill = try String(contentsOf: installedSkillURL.appending(path: "SKILL.md"), encoding: .utf8)
            let metadata = try String(
                contentsOf: installedSkillURL.appending(path: "agents/openai.yaml"),
                encoding: .utf8
            )
            #expect(skill.contains("name: projects-optimizer"))
            #expect(metadata.contains("$projects-optimizer"))
            #expect(!FileManager.default.fileExists(atPath: obsoleteSkillURL.path))
            #expect(try permissions(of: installedSkillURL) == 0o700)
            #expect(try permissions(of: installedSkillURL.appending(path: "agents")) == 0o700)
            #expect(try permissions(of: installedSkillURL.appending(path: "SKILL.md")) == 0o600)
            #expect(try permissions(of: installedSkillURL.appending(path: "agents/openai.yaml")) == 0o600)
            await transport.close()
        }

        @Test
        func replacesSymlinkedPresetWithoutModifyingItsTarget() throws {
            let rootURL = URL.temporaryDirectory
                .appending(path: "dahlia-codex-skill-link-\(UUID().uuidString)", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: rootURL) }

            let homeURL = try ApplicationSupportCodexHomeLocator(applicationSupportURL: rootURL).homeURL()
            let skillsURL = homeURL.appending(path: "skills", directoryHint: .isDirectory)
            let installedSkillURL = skillsURL
                .appending(path: BundledCodexPresetSkillInstaller.skillName, directoryHint: .isDirectory)
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
#endif
