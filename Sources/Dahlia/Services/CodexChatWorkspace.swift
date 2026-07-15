import Foundation

protocol CodexChatWorkspaceLocating: Sendable {
    func workspaceURL() throws -> URL
}

struct ApplicationSupportCodexChatWorkspaceLocator: CodexChatWorkspaceLocating {
    private let applicationSupportURL: URL?

    init(applicationSupportURL: URL? = nil) {
        self.applicationSupportURL = applicationSupportURL
    }

    func workspaceURL() throws -> URL {
        let baseURL = applicationSupportURL ?? URL.applicationSupportDirectory
        let workspaceURL = baseURL
            .appending(path: "Dahlia", directoryHint: .isDirectory)
            .appending(path: "CodexChatWorkspace", directoryHint: .isDirectory)

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
