import CryptoKit
import DahliaMeetingAccess
import Foundation
import GRDB

actor SearchDictionaryService {
    static let neologdVersion = "2.3.4"
    static let neologdSHA256 = "f90a49e357052f88d4f641d05c6271ec5b597096903075f4774b4c1369085daf"
    static let neologdURL = URL(string: "https://github.com/lindera/lindera/releases/download/v2.3.4/lindera-ipadic-neologd-2.3.4.zip")!

    private let database: AppDatabaseManager
    let directory: URL

    init(database: AppDatabaseManager, directory: URL? = nil) {
        self.database = database
        self.directory = directory ?? (database.dbQueue.path == ":memory:"
            ? FileManager.default.temporaryDirectory.appending(path: "dahlia-search-dictionaries-\(UUID.v7())")
            : URL(filePath: database.dbQueue.path).deletingLastPathComponent().appending(path: "SearchDictionaries"))
    }

    private var neologdDirectory: URL {
        directory.appending(path: "neologd-\(Self.neologdVersion)-\(Self.neologdSHA256)")
    }

    func snapshot() async throws -> (preferred: SearchDictionaryConfiguration, active: SearchDictionaryConfiguration, neologdPath: String?) {
        let configurations = try await database.dbQueue.read { db in
            try (SearchDictionaryConfiguration.read(in: db, preferred: true), SearchDictionaryConfiguration.read(in: db))
        }
        let installed = FileManager.default.fileExists(atPath: neologdDirectory.appending(path: "metadata.json").path)
        return (configurations.0, configurations.1, installed ? neologdDirectory.path : nil)
    }

    /// Selection is a draft: only the explicit Rebuild action activates it.
    func select(_ configuration: SearchDictionaryConfiguration) async throws {
        try Task.checkCancellation()
        let previous = try await snapshot().preferred
        if (configuration.dictionaryPath != nil && configuration.dictionaryPath != previous.dictionaryPath)
            || (configuration.userDictionaryPath != nil && configuration.userDictionaryPath != previous.userDictionaryPath) {
            do {
                try configuration.validate()
            } catch {
                throw configuration.userDictionaryPath != nil ? SearchDictionaryError.invalidUserDictionary : SearchDictionaryError.invalidDictionary
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

    func downloadNeologd(session: URLSession = .shared) async throws {
        if !FileManager.default.fileExists(atPath: neologdDirectory.path) {
            let (archive, response) = try await session.download(from: Self.neologdURL)
            defer { try? FileManager.default.removeItem(at: archive) }
            guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                throw SearchDictionaryError.downloadFailed
            }
            try installNeologd(archive: archive)
        }
        var configuration = try await snapshot().preferred
        configuration.dictionaryPath = neologdDirectory.path
        try await select(configuration)
    }

    func installNeologd(archive: URL) throws {
        let data = try Data(contentsOf: archive, options: .mappedIfSafe)
        guard Self.sha256(data) == Self.neologdSHA256 else { throw SearchDictionaryError.checksumMismatch }
        try Task.checkCancellation()
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = directory.appending(path: ".staging-\(UUID.v7())")
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: staging) }
        // The checksum pins this archive; bsdtar also rejects traversal outside staging.
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/tar")
        process.arguments = ["-xf", archive.path, "-C", staging.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw SearchDictionaryError.invalidDictionary }
        let extracted = staging.appending(path: "lindera-ipadic-neologd")
        try SearchDictionaryConfiguration(dictionaryPath: extracted.path).validate()
        try Task.checkCancellation()
        if !fileManager.fileExists(atPath: neologdDirectory.path) {
            try fileManager.moveItem(at: extracted, to: neologdDirectory)
        }
    }

    func importUserDictionary(from source: URL) async throws {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 10 * 1024 * 1024 else { throw SearchDictionaryError.invalidUserDictionary }
        let data = try Data(contentsOf: source)
        guard let text = String(data: data, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SearchDictionaryError.invalidUserDictionary }
        let target = directory.appending(path: "user-\(Self.sha256(data)).csv")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: target.path) {
            try data.write(to: target, options: .atomic)
        }
        var configuration = try await snapshot().preferred
        configuration.userDictionaryPath = target.path
        configuration.userDictionaryName = source.lastPathComponent
        try await select(configuration)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
