import Foundation

enum ProjectFolderSafety {
    static func status(of url: URL, inside workspaceURL: URL) -> ProjectFolderStatus {
        let fileManager = FileManager.default
        let workspace = workspaceURL.standardizedFileURL
        let candidate = url.standardizedFileURL
        guard candidate.pathComponents.starts(with: workspace.pathComponents) else { return .unsafe }

        var current = workspace
        for component in candidate.pathComponents.dropFirst(workspace.pathComponents.count) {
            current.append(path: component, directoryHint: .isDirectory)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: current.path, isDirectory: &isDirectory) else {
                return .missing
            }
            guard isDirectory.boolValue,
                  let values = try? current.resourceValues(forKeys: [.isSymbolicLinkKey]),
                  values.isSymbolicLink != true else {
                return .unsafe
            }
        }

        let workspacePath = workspace.resolvingSymlinksInPath().standardizedFileURL.path
        let candidatePath = candidate.resolvingSymlinksInPath().standardizedFileURL.path
        return candidatePath.hasPrefix(workspacePath + "/") ? .available : .unsafe
    }

    static func isSafeDirectory(_ url: URL, inside workspaceURL: URL) -> Bool {
        status(of: url, inside: workspaceURL) == .available
    }
}
