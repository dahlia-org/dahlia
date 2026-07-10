import Foundation

struct LocatedVaultSummaryFile: Equatable {
    let meetingId: UUID
    let relativePath: String
    let url: URL
}

/// Vault 内の要約 Markdown と、DB に保存する Vault 相対パスを相互変換する。
enum VaultSummaryFileLocator {
    static func findSummaryFile(
        storedRelativePath: String?,
        projectURL: URL?,
        vaultURL: URL,
        meetingId: UUID
    ) -> URL? {
        if let storedRelativePath,
           let storedURL = fileURL(for: storedRelativePath, vaultURL: vaultURL),
           let storedSummary = locatedSummaryFile(at: storedURL, vaultURL: vaultURL),
           storedSummary.meetingId == meetingId {
            return storedSummary.url
        }

        if let projectURL,
           let projectMatch = locatedSummaryFiles(in: projectURL, recursively: false)
           .first(where: { $0.meetingId == meetingId }) {
            return projectMatch.url
        }

        return locatedSummaryFiles(in: vaultURL, recursively: true)
            .first(where: { $0.meetingId == meetingId })?
            .url
    }

    static func locatedSummaryFiles(in vaultURL: URL) -> [LocatedVaultSummaryFile] {
        locatedSummaryFiles(in: vaultURL, recursively: true)
    }

    static func locatedSummaryFile(at fileURL: URL, vaultURL: URL) -> LocatedVaultSummaryFile? {
        guard fileURL.pathExtension.lowercased() == "md",
              let meetingId = meetingId(in: fileURL),
              let relativePath = relativePath(for: fileURL, vaultURL: vaultURL)
        else { return nil }

        return LocatedVaultSummaryFile(meetingId: meetingId, relativePath: relativePath, url: fileURL)
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

    private static func locatedSummaryFiles(in directoryURL: URL, recursively: Bool) -> [LocatedVaultSummaryFile] {
        let options: FileManager.DirectoryEnumerationOptions = recursively
            ? [.skipsHiddenFiles]
            : [.skipsHiddenFiles, .skipsSubdirectoryDescendants]

        guard let enumerator = FileManager.default.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: options
        ) else { return [] }

        var locations: [LocatedVaultSummaryFile] = []
        while let url = enumerator.nextObject() as? URL {
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey]) else { continue }

            if values.isDirectory == true {
                if url.lastPathComponent == "_dahlia" {
                    enumerator.skipDescendants()
                }
                continue
            }

            guard values.isRegularFile == true,
                  let location = locatedSummaryFile(at: url, vaultURL: directoryURL)
            else { continue }
            locations.append(location)
        }

        return locations.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }

    private static func meetingId(in fileURL: URL) -> UUID? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }

        guard let data = try? handle.read(upToCount: 4096),
              let head = String(data: data, encoding: .utf8)
        else { return nil }

        for line in head.split(whereSeparator: \Character.isNewline) {
            let fields = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2,
                  fields[0].trimmingCharacters(in: .whitespaces).lowercased() == "meeting_id"
            else { continue }

            let value = fields[1]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return UUID(uuidString: value)
        }

        return nil
    }
}
