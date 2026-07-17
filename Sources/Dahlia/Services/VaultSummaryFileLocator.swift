import Foundation

/// Vault 内の要約 Markdown と、DB に保存する Vault 相対パスを相互変換する。
enum VaultSummaryFileLocator {
    static func findSummaryFile(
        storedRelativePath: String?,
        vaultURL: URL
    ) -> URL? {
        guard let storedRelativePath,
              let storedURL = fileURL(for: storedRelativePath, vaultURL: vaultURL),
              storedURL.pathExtension.lowercased() == "md",
              (try? storedURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        else { return nil }
        return storedURL
    }

    static func relativePath(for fileURL: URL, vaultURL: URL) -> String? {
        let vaultPath = vaultURL.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        let prefix = vaultPath.hasSuffix("/") ? vaultPath : vaultPath + "/"

        guard filePath.hasPrefix(prefix) else { return nil }
        return String(filePath.dropFirst(prefix.count))
    }

    static func fileURL(for relativePath: String, vaultURL: URL) -> URL? {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else { return nil }

        let vaultPath = vaultURL.standardizedFileURL.path
        let candidate = vaultURL.appending(path: relativePath).standardizedFileURL
        let prefix = vaultPath.hasSuffix("/") ? vaultPath : vaultPath + "/"

        guard candidate.path.hasPrefix(prefix) else { return nil }
        return candidate
    }
}
