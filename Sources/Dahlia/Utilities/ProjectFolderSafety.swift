import Foundation

enum ProjectFolderSafety {
    static func status(of url: URL, inside vaultURL: URL) -> ProjectFolderStatus {
        let fileManager = FileManager.default
        let vault = vaultURL.standardizedFileURL
        let candidate = url.standardizedFileURL
        guard candidate.pathComponents.starts(with: vault.pathComponents) else { return .unsafe }

        var current = vault
        for component in candidate.pathComponents.dropFirst(vault.pathComponents.count) {
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

        let vaultPath = vault.resolvingSymlinksInPath().standardizedFileURL.path
        let candidatePath = candidate.resolvingSymlinksInPath().standardizedFileURL.path
        return candidatePath.hasPrefix(vaultPath + "/") ? .available : .unsafe
    }

    static func isSafeDirectory(_ url: URL, inside vaultURL: URL) -> Bool {
        status(of: url, inside: vaultURL) == .available
    }
}
