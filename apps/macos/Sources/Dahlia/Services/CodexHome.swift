import DahliaRuntimeSupport
import Foundation

struct ApplicationSupportCodexHomeLocator {
    private let applicationSupportURL: URL?

    init(applicationSupportURL: URL? = nil) {
        self.applicationSupportURL = applicationSupportURL
    }

    func homeURL() throws -> URL {
        try homeURL(connectionID: CodexRuntimeContextStore.shared.provider.accountConnectionID)
    }

    func homeURL(connectionID: UUID?) throws -> URL {
        let dahliaApplicationSupportURL = applicationSupportURL.map {
            $0.appending(path: "Dahlia", directoryHint: .isDirectory)
        } ?? DahliaApplicationSupport.currentDirectoryURL
        let homeURL: URL = if let connectionID {
            dahliaApplicationSupportURL
                .appending(path: "CodexAccounts", directoryHint: .isDirectory)
                .appending(path: connectionID.uuidString.lowercased(), directoryHint: .isDirectory)
        } else {
            dahliaApplicationSupportURL
                .appending(path: "Codex", directoryHint: .isDirectory)
        }

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

    func removeHome(connectionID: UUID) throws {
        let url = try homeURL(connectionID: connectionID)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}
