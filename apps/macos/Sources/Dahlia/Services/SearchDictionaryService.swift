import CryptoKit
import DahliaMeetingAccess
import Foundation
import GRDB

actor SearchDictionaryService {
    private let database: AppDatabaseManager
    private var availableReleases: [SearchNeologdRelease]?
    let directory: URL

    init(database: AppDatabaseManager, directory: URL? = nil) {
        self.database = database
        self.directory = directory ?? (database.dbQueue.path == ":memory:"
            ? FileManager.default.temporaryDirectory.appending(path: "dahlia-search-dictionaries-\(UUID.v7())")
            : URL(filePath: database.dbQueue.path).deletingLastPathComponent().appending(path: "Search"))
    }

    private var catalogURL: URL { directory.appending(path: "neologd-releases.json") }

    private func cachedReleases() -> [SearchNeologdRelease] {
        if let availableReleases { return availableReleases }
        let cached = (try? Data(contentsOf: catalogURL)).flatMap { try? JSONDecoder().decode([SearchNeologdRelease].self, from: $0) } ?? []
        let releases = SearchNeologdCatalog.latestThree(cached)
        let result = releases.isEmpty ? SearchNeologdCatalog.fallback : releases
        availableReleases = result
        return result
    }

    func refreshAvailableReleases(session: URLSession = .shared) async throws {
        let releases = try await SearchNeologdCatalog.fetch(session: session)
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(releases).write(to: catalogURL, options: .atomic)
        availableReleases = releases
    }

    private func installedReleases() throws -> [SearchNeologdRelease] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])
            .compactMap { url in
                guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true,
                      FileManager.default.fileExists(atPath: url.appending(path: "metadata.json").path) else { return nil }
                return SearchNeologdRelease(directoryName: url.lastPathComponent)
            }
    }

    func neologdOptions() throws -> (releases: [SearchNeologdRelease], installedIDs: Set<String>) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let installed = try installedReleases()
        var releases = cachedReleases()
        for release in installed where !releases.contains(where: { $0.id == release.id }) {
            releases.append(release)
        }
        return (releases.sorted(by: SearchNeologdRelease.newerFirst), Set(installed.map(\.id)))
    }

    var userDictionaryURL: URL { directory.appending(path: "user-dict.csv") }

    private func configurations() async throws -> (preferred: SearchDictionaryConfiguration, active: SearchDictionaryConfiguration) {
        try await database.dbQueue.read { db in
            try (SearchDictionaryConfiguration.read(in: db, preferred: true), SearchDictionaryConfiguration.read(in: db))
        }
    }

    func snapshot() async throws -> SearchDictionarySnapshot {
        let stored = try await configurations()
        try prepareStorage(preferred: stored.preferred)
        var preferred = stored.preferred
        let options = try neologdOptions()
        if let path = preferred.dictionaryPath,
           let release = options.releases.first(where: { $0.id == URL(filePath: path).lastPathComponent }),
           options.installedIDs.contains(release.id), release.version.hasPrefix("6.") {
            preferred.dictionaryPath = directory.appending(path: release.id).path
        }
        var validationError: String?
        do {
            let size = try userDictionaryURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 10 * 1024 * 1024 else { throw SearchDictionaryError.invalidUserDictionary }
            let data = try Data(contentsOf: userDictionaryURL)
            let hasEntries = try SearchUserDictionaryCSV.validate(data)
            preferred = try userConfiguration(data: data, hasEntries: hasEntries, preferred: preferred)
            if preferred != stored.preferred { try await select(preferred) }
        } catch {
            validationError = error.localizedDescription
        }
        return SearchDictionarySnapshot(
            preferred: preferred, active: stored.active, neologdReleases: options.releases, installedNeologdIDs: options.installedIDs,
            userDictionaryPath: userDictionaryURL.path, userDictionaryError: validationError
        )
    }

    private func prepareStorage(preferred: SearchDictionaryConfiguration) throws {
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        if !files.fileExists(atPath: userDictionaryURL.path) {
            // Leave existing active files in place until an explicit rebuild switches every connection.
            if let path = preferred.userDictionaryPath,
               URL(filePath: path).deletingLastPathComponent().lastPathComponent != "Snapshots",
               files.fileExists(atPath: path) {
                try files.copyItem(at: URL(filePath: path), to: userDictionaryURL)
            } else {
                try Data("Databricks,カスタム名詞,データブリックス\n".utf8).write(to: userDictionaryURL, options: .atomic)
            }
        }
        let legacy = directory.deletingLastPathComponent().appending(path: "SearchDictionaries")
        if files.fileExists(atPath: legacy.path) {
            for source in try files.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil) {
                guard let release = SearchNeologdRelease(directoryName: source.lastPathComponent) else { continue }
                let target = directory.appending(path: release.id)
                if !files.fileExists(atPath: target.path) {
                    let staging = directory.appending(path: ".migration-\(UUID.v7())")
                    defer { try? files.removeItem(at: staging) }
                    try files.copyItem(at: source, to: staging)
                    try files.moveItem(at: staging, to: target)
                }
            }
        }
    }

    /// Selection is a draft: only the explicit Rebuild action activates it.
    func select(_ configuration: SearchDictionaryConfiguration) async throws {
        try Task.checkCancellation()
        let previous = try await configurations().preferred
        let systemChanged = configuration.dictionaryPath != previous.dictionaryPath
        if systemChanged, configuration.dictionaryPath != nil {
            do {
                try SearchDictionaryConfiguration(dictionaryPath: configuration.dictionaryPath).validate()
            } catch {
                throw SearchDictionaryError.invalidDictionary
            }
        }
        if configuration.userDictionaryPath != nil,
           systemChanged || configuration.userDictionaryPath != previous.userDictionaryPath {
            do {
                try configuration.validate()
            } catch {
                throw SearchDictionaryError.invalidUserDictionary
            }
        }
        try Task.checkCancellation()
        try await database.dbQueue.write { db in
            try db.execute(sql: """
            UPDATE search_dictionary_configuration
            SET dictionaryPath = ?, userDictionaryPath = ?, userDictionaryName = ? WHERE id = 2
            """, arguments: [configuration.dictionaryPath, configuration.userDictionaryPath, configuration.userDictionaryName])
        }
    }

    func selectNeologd(_ release: SearchNeologdRelease?, session: URLSession = .shared) async throws {
        try Task.checkCancellation()
        var path: String?
        if let release {
            guard release.isValid else { throw SearchDictionaryError.invalidDictionary }
            let target = directory.appending(path: release.id)
            if !FileManager.default.fileExists(atPath: target.appending(path: "metadata.json").path) {
                guard cachedReleases().contains(release) else { throw SearchDictionaryError.catalogUnavailable }
                let (archive, response) = try await session.download(from: release.downloadURL)
                defer { try? FileManager.default.removeItem(at: archive) }
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw SearchDictionaryError.downloadFailed }
                try installNeologd(archive: archive, release: release)
            }
            path = target.path
        }
        // Read after the download so a newer user dictionary edit cannot be overwritten by an old draft.
        var configuration = try await configurations().preferred
        configuration.dictionaryPath = path
        try await select(configuration)
    }

    func installNeologd(archive: URL, release: SearchNeologdRelease = SearchNeologdCatalog.fallback[0]) throws {
        guard release.isValid else { throw SearchDictionaryError.invalidDictionary }
        let data = try Data(contentsOf: archive, options: .mappedIfSafe)
        guard Self.sha256(data) == release.sha256 else { throw SearchDictionaryError.checksumMismatch }
        try Task.checkCancellation()
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = directory.appending(path: ".staging-\(UUID.v7())")
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: staging) }
        // The checksum comes from the official release; bsdtar rejects traversal outside staging.
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/tar")
        process.arguments = ["-xf", archive.path, "-C", staging.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw SearchDictionaryError.invalidDictionary }
        let extracted = staging.appending(path: "lindera-ipadic-neologd")
        do {
            try SearchDictionaryConfiguration(dictionaryPath: extracted.path).validate()
        } catch {
            throw SearchDictionaryError.invalidDictionary
        }
        try Task.checkCancellation()
        let target = directory.appending(path: release.id)
        if !fileManager.fileExists(atPath: target.path) {
            try fileManager.moveItem(at: extracted, to: target)
        }
    }

    func importUserDictionary(from source: URL) async throws {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 10 * 1024 * 1024 else { throw SearchDictionaryError.invalidUserDictionary }
        let data = try Data(contentsOf: source)
        guard try SearchUserDictionaryCSV.validate(data) else { throw SearchDictionaryError.invalidUserDictionary }
        try await saveUserDictionary(data, hasEntries: true)
    }

    func clearUserDictionary() async throws {
        try await saveUserDictionary(Data(), hasEntries: false)
    }

    private func saveUserDictionary(_ data: Data, hasEntries: Bool) async throws {
        try Task.checkCancellation()
        let stored = try await configurations()
        try prepareStorage(preferred: stored.preferred)
        let configuration = try userConfiguration(data: data, hasEntries: hasEntries, preferred: stored.preferred)
        try Task.checkCancellation()
        try data.write(to: userDictionaryURL, options: .atomic)
        try await select(configuration)
    }

    private func userConfiguration(
        data: Data, hasEntries: Bool, preferred: SearchDictionaryConfiguration
    ) throws -> SearchDictionaryConfiguration {
        var configuration = preferred
        configuration.userDictionaryPath = nil
        configuration.userDictionaryName = nil
        if hasEntries {
            let snapshots = directory.appending(path: "Snapshots")
            try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
            let target = snapshots.appending(path: "user-\(Self.sha256(data)).csv")
            if !FileManager.default.fileExists(atPath: target.path) {
                try data.write(to: target, options: .atomic)
            }
            configuration.userDictionaryPath = target.path
            configuration.userDictionaryName = "user-dict.csv"
            if configuration.userDictionaryPath != preferred.userDictionaryPath {
                do { try configuration.validate() } catch { throw SearchDictionaryError.invalidUserDictionary }
            }
        }
        return configuration
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
