import Foundation

/// Workspace 内の要約 Markdown と、DB に保存する Workspace 相対パスを相互変換する。
public enum WorkspaceSummaryFileLocator {
    public static func findSummaryFile(
        storedRelativePath: String?,
        workspaceURL: URL
    ) -> URL? {
        guard let storedRelativePath,
              let storedURL = fileURL(for: storedRelativePath, workspaceURL: workspaceURL),
              storedURL.pathExtension.lowercased() == "md",
              (try? storedURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        else { return nil }
        return storedURL
    }

    public static func relativePath(for fileURL: URL, workspaceURL: URL) -> String? {
        let workspacePath = workspaceURL.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        let prefix = workspacePath.hasSuffix("/") ? workspacePath : workspacePath + "/"

        guard filePath.hasPrefix(prefix) else { return nil }
        return String(filePath.dropFirst(prefix.count))
    }

    public static func fileURL(for relativePath: String, workspaceURL: URL) -> URL? {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else { return nil }

        let workspacePath = workspaceURL.standardizedFileURL.path
        let candidate = workspaceURL.appending(path: relativePath).standardizedFileURL
        let prefix = workspacePath.hasSuffix("/") ? workspacePath : workspacePath + "/"

        guard candidate.path.hasPrefix(prefix) else { return nil }
        return candidate
    }
}
