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
            try Data("#!/bin/sh\n/bin/pwd\n".utf8).write(to: executableURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executableURL.path)

            let homeLocator = ApplicationSupportCodexHomeLocator(applicationSupportURL: rootURL)
            let expectedHomeURL = try homeLocator.homeURL()
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
            await transport.close()
        }
    }

    private struct FixedCodexExecutableLocator: CodexExecutableLocating {
        let url: URL

        func executableURL() throws -> URL {
            url
        }
    }
#endif
