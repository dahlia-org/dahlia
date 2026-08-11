import DahliaRuntimeSupport
import Foundation

protocol CodexHomeLocating: Sendable {
    func homeURL() throws -> URL
}

struct ApplicationSupportCodexHomeLocator: CodexHomeLocating {
    private let applicationSupportURL: URL?

    init(applicationSupportURL: URL? = nil) {
        self.applicationSupportURL = applicationSupportURL
    }

    func homeURL() throws -> URL {
        let dahliaApplicationSupportURL = applicationSupportURL.map {
            $0.appending(path: "Dahlia", directoryHint: .isDirectory)
        } ?? DahliaApplicationSupport.currentDirectoryURL
        let homeURL = dahliaApplicationSupportURL
            .appending(path: "Codex", directoryHint: .isDirectory)

        do {
            try FileManager.default.createDirectory(
                at: homeURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: homeURL.path
            )
        } catch {
            throw CodexAppServerError.launchFailed(error.localizedDescription)
        }
        return homeURL
    }
}
