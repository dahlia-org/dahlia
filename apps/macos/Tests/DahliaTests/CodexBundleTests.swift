import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct CodexBundleTests {
        @Test
        func executableURLRequiresCodexAndCodeModeHost() throws {
            let helpersURL = try temporaryHelpersDirectory()
            defer { try? FileManager.default.removeItem(at: helpersURL) }
            let codexURL = helpersURL.appending(path: "codex")
            let hostURL = helpersURL.appending(path: "codex-code-mode-host")
            try makeExecutable(at: codexURL)
            try makeExecutable(at: hostURL)

            #expect(try CodexBundle.executableURL(inHelpersDirectory: helpersURL) == codexURL)
        }

        @Test
        func executableURLRejectsBundleWithoutCodeModeHost() throws {
            let helpersURL = try temporaryHelpersDirectory()
            defer { try? FileManager.default.removeItem(at: helpersURL) }
            try makeExecutable(at: helpersURL.appending(path: "codex"))

            #expect(throws: CodexAppServerError.helperNotBundled) {
                try CodexBundle.executableURL(inHelpersDirectory: helpersURL)
            }
        }

        private func temporaryHelpersDirectory() throws -> URL {
            let url = FileManager.default.temporaryDirectory
                .appending(path: "dahlia-codex-bundle-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        private func makeExecutable(at url: URL) throws {
            try Data().write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }
#endif
