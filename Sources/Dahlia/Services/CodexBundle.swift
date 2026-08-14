import Foundation

protocol CodexExecutableLocating: Sendable {
    func executableURL() throws -> URL
}

struct BundleCodexExecutableLocator: CodexExecutableLocating {
    func executableURL() throws -> URL {
        try CodexBundle.executableURL()
    }
}

enum CodexBundle {
    nonisolated static let version = "0.147.0"
    nonisolated static let sourceCommit = "be6e8eac029b183056b7e4402879f15d2c85f61b"

    nonisolated static func executableURL(in bundle: Bundle = .main) throws -> URL {
        let helpersURL = bundle.bundleURL
            .appending(path: "Contents", directoryHint: .isDirectory)
            .appending(path: "Helpers", directoryHint: .isDirectory)
        return try executableURL(inHelpersDirectory: helpersURL)
    }

    nonisolated static func executableURL(inHelpersDirectory helpersURL: URL) throws -> URL {
        let codexURL = helpersURL
            .appending(path: "codex")
        let codeModeHostURL = helpersURL
            .appending(path: "codex-code-mode-host")
        guard FileManager.default.isExecutableFile(atPath: codexURL.path),
              FileManager.default.isExecutableFile(atPath: codeModeHostURL.path)
        else {
            throw CodexAppServerError.helperNotBundled
        }
        return codexURL
    }
}

enum DahliaMCPBundle {
    nonisolated static func expectedExecutableURL(in bundle: Bundle = .main) -> URL {
        bundle.bundleURL
            .appending(path: "Contents", directoryHint: .isDirectory)
            .appending(path: "Helpers", directoryHint: .isDirectory)
            .appending(path: "dahlia-mcp")
    }

    nonisolated static func executableURL(in bundle: Bundle = .main) throws -> URL {
        let url = expectedExecutableURL(in: bundle)
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw CodexAppServerError.helperNotBundled
        }
        return url
    }
}
