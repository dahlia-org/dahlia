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
    nonisolated static let version = "0.146.0"
    nonisolated static let sourceCommit = "e363b08c9175ac1cbe5893615dd2cb9ddf95043b"

    nonisolated static func executableURL(in bundle: Bundle = .main) throws -> URL {
        let url = bundle.bundleURL
            .appending(path: "Contents", directoryHint: .isDirectory)
            .appending(path: "Helpers", directoryHint: .isDirectory)
            .appending(path: "codex")
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw CodexAppServerError.helperNotBundled
        }
        return url
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
