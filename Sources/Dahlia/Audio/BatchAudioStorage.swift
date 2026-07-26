import Foundation

enum BatchAudioStorage {
    /// クラッシュ復旧対象のCAFは、OSの自動削除対象にならないApplication Supportへ置く。
    static var managedRootURL: URL {
        AppDatabaseManager.databaseURL
            .deletingLastPathComponent()
            .appending(path: "BatchAudio", directoryHint: .isDirectory)
    }

    static func removeFilesChecked(baseURL: URL, relativePaths: [String]) throws {
        for relativePath in relativePaths {
            guard let finalURL = safeURL(baseURL: baseURL, relativePath: relativePath) else {
                throw RecordingAudioStoreError.invalidPath
            }
            let partialURL = finalURL.deletingPathExtension().appendingPathExtension("partial.caf")
            if FileManager.default.fileExists(atPath: finalURL.path) {
                try FileManager.default.removeItem(at: finalURL)
            }
            if FileManager.default.fileExists(atPath: partialURL.path) {
                try FileManager.default.removeItem(at: partialURL)
            }
            guard !FileManager.default.fileExists(atPath: finalURL.path),
                  !FileManager.default.fileExists(atPath: partialURL.path) else {
                throw RecordingAudioStoreError.storageUnavailable
            }
            removeEmptyParentDirectories(of: finalURL, stoppingAt: baseURL)
        }
    }

    static func baseURL(
        for location: RecordingAudioStorageLocation,
        managedRootURL: URL = managedRootURL,
        vaultURL: URL
    ) -> URL {
        switch location {
        case .managed:
            managedRootURL
        case .vault:
            vaultURL
        }
    }

    static func safeURL(baseURL: URL, relativePath: String) -> URL? {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else { return nil }
        let standardizedBaseURL = baseURL.standardizedFileURL.resolvingSymlinksInPath()
        let candidateURL = standardizedBaseURL
            .appending(path: relativePath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let directoryPrefix = standardizedBaseURL.path.hasSuffix("/")
            ? standardizedBaseURL.path
            : standardizedBaseURL.path + "/"
        guard candidateURL.path.hasPrefix(directoryPrefix) else { return nil }
        return candidateURL
    }

    private static func removeEmptyParentDirectories(of fileURL: URL, stoppingAt baseURL: URL) {
        let standardizedBaseURL = baseURL.standardizedFileURL.resolvingSymlinksInPath()
        let directoryPrefix = standardizedBaseURL.path.hasSuffix("/")
            ? standardizedBaseURL.path
            : standardizedBaseURL.path + "/"
        var directoryURL = fileURL.deletingLastPathComponent()

        while directoryURL.path.hasPrefix(directoryPrefix) {
            do {
                guard try FileManager.default.contentsOfDirectory(atPath: directoryURL.path).isEmpty else { return }
                try FileManager.default.removeItem(at: directoryURL)
                directoryURL = directoryURL.deletingLastPathComponent()
            } catch {
                return
            }
        }
    }
}
