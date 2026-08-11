import DahliaRuntimeSupport
import Foundation

protocol CodexChatWorkspaceLocating: Sendable {
    func workspaceURL(vaultID: UUID) throws -> URL
}

struct ApplicationSupportCodexChatWorkspaceLocator: CodexChatWorkspaceLocating {
    private let applicationSupportURL: URL?

    init(applicationSupportURL: URL? = nil) {
        self.applicationSupportURL = applicationSupportURL
    }

    func workspaceURL(vaultID: UUID) throws -> URL {
        let dahliaApplicationSupportURL = applicationSupportURL.map {
            $0.appending(path: "Dahlia", directoryHint: .isDirectory)
        } ?? DahliaApplicationSupport.currentDirectoryURL
        let workspaceURL = dahliaApplicationSupportURL
            .appending(path: "CodexChatWorkspace", directoryHint: .isDirectory)
            .appending(path: vaultID.uuidString.lowercased(), directoryHint: .isDirectory)

        do {
            try FileManager.default.createDirectory(
                at: workspaceURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: workspaceURL.path
            )
        } catch {
            throw CodexAppServerError.launchFailed(error.localizedDescription)
        }
        return workspaceURL
    }
}
