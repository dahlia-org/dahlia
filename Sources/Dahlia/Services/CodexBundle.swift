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
    nonisolated static let version = "0.144.4"
    nonisolated static let sourceCommit = "8c68d4c87dc54d38861f5114e920c3de2efa5876"

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
