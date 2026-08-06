import CryptoKit
import DahliaRuntimeSupport
import FluidAudio
import Foundation

struct SpeakerModelAssetManifest: Codable, Sendable {
    struct File: Codable, Hashable, Sendable {
        let relativePath: String
        let byteCount: Int64
        let sha256: String
    }

    let repository: String
    let revision: String
    let license: String
    let totalByteCount: Int64
    let files: [File]

    static func bundled() throws -> Self {
        guard let url = Bundle.appModule.url(
            forResource: "SpeakerDiarizationModelManifest",
            withExtension: "json"
        ) else {
            throw SpeakerModelAssetError.manifestUnavailable
        }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    var assetFingerprint: String {
        let identity = ([repository, revision] + files.sorted { $0.relativePath < $1.relativePath }.flatMap {
            [$0.relativePath, String($0.byteCount), $0.sha256]
        }).joined(separator: "\n")
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct SpeakerModelAssetProgress: Equatable, Sendable {
    let completedByteCount: Int64
    let totalByteCount: Int64
    let currentFile: String?
}

enum SpeakerModelAssetError: Error, Equatable {
    case manifestUnavailable
    case invalidResponse(URL)
    case missingFile(String)
    case byteCountMismatch(path: String, expected: Int64, actual: Int64)
    case checksumMismatch(path: String)
    case totalByteCountMismatch(expected: Int64, actual: Int64)
}

protocol SpeakerModelAssetFetching: Sendable {
    func data(from url: URL) async throws -> Data
}

struct URLSessionSpeakerModelAssetFetcher: SpeakerModelAssetFetching {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func data(from url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        guard let response = response as? HTTPURLResponse,
              (200 ..< 300).contains(response.statusCode) else {
            throw SpeakerModelAssetError.invalidResponse(url)
        }
        return data
    }
}

actor SpeakerModelAssetManager {
    /// FluidAudio does not expose its package version at runtime. A test reads
    /// Package.swift and Package.resolved and requires this identity component to match both pins.
    static let fluidAudioVersion = "0.15.5"
    static var repositoryFolderName: String { Repo.diarizer.folderName }

    private let manifest: SpeakerModelAssetManifest
    private let managedRootURL: URL
    private let fetcher: any SpeakerModelAssetFetching
    private let fileManager: FileManager
    private var activeAcquisition: Task<URL, Error>?

    init(
        managedRootURL: URL = DahliaApplicationSupport.currentDirectoryURL
            .appending(path: "Models/SpeakerDiarization", directoryHint: .isDirectory),
        manifest: SpeakerModelAssetManifest? = nil,
        fetcher: any SpeakerModelAssetFetching = URLSessionSpeakerModelAssetFetcher(),
        fileManager: FileManager = .default
    ) throws {
        self.managedRootURL = managedRootURL
        self.manifest = try manifest ?? .bundled()
        self.fetcher = fetcher
        self.fileManager = fileManager
    }

    func acquisition() -> AsyncThrowingStream<SpeakerModelAssetProgress, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    _ = try await acquire { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    @discardableResult
    func acquire(
        progress: @escaping @Sendable (SpeakerModelAssetProgress) -> Void = { _ in }
    ) async throws -> URL {
        if let activeAcquisition {
            return try await awaitAcquisition(activeAcquisition)
        }

        let task = Task { try await performAcquisition(progress: progress) }
        activeAcquisition = task
        do {
            let url = try await awaitAcquisition(task)
            activeAcquisition = nil
            return url
        } catch {
            activeAcquisition = nil
            throw error
        }
    }

    private func awaitAcquisition(_ task: Task<URL, Error>) async throws -> URL {
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func performAcquisition(
        progress: @escaping @Sendable (SpeakerModelAssetProgress) -> Void
    ) async throws -> URL {
        let repositoryURL = installedRepositoryURL
        if (try? verifyRepository(at: repositoryURL)) == true {
            progress(.init(
                completedByteCount: manifest.totalByteCount,
                totalByteCount: manifest.totalByteCount,
                currentFile: nil
            ))
            return repositoryURL
        }

        try fileManager.createDirectory(at: revisionRootURL, withIntermediateDirectories: true)
        let temporaryURL = revisionRootURL.appending(
            path: "." + Self.repositoryFolderName + "-" + UUID.v7().uuidString + ".temporary",
            directoryHint: .isDirectory
        )
        try fileManager.createDirectory(at: temporaryURL, withIntermediateDirectories: true)

        do {
            let receivedByteCount = try await downloadAssets(to: temporaryURL, progress: progress)
            guard receivedByteCount == manifest.totalByteCount else {
                throw SpeakerModelAssetError.totalByteCountMismatch(
                    expected: manifest.totalByteCount,
                    actual: receivedByteCount
                )
            }
            _ = try verifyRepository(at: temporaryURL)
            try Task.checkCancellation()
            if fileManager.fileExists(atPath: repositoryURL.path) {
                _ = try fileManager.replaceItemAt(repositoryURL, withItemAt: temporaryURL)
            } else {
                try fileManager.moveItem(at: temporaryURL, to: repositoryURL)
            }
            return repositoryURL
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }

    private func downloadAssets(
        to temporaryURL: URL,
        progress: @escaping @Sendable (SpeakerModelAssetProgress) -> Void
    ) async throws -> Int64 {
        var receivedByteCount: Int64 = 0
        progress(.init(completedByteCount: 0, totalByteCount: manifest.totalByteCount, currentFile: nil))
        for file in manifest.files {
            try Task.checkCancellation()
            let data = try await fetcher.data(from: Self.downloadURL(for: file, manifest: manifest))
            let byteCount = Int64(data.count)
            guard byteCount == file.byteCount else {
                throw SpeakerModelAssetError.byteCountMismatch(
                    path: file.relativePath,
                    expected: file.byteCount,
                    actual: byteCount
                )
            }
            guard Self.sha256(of: data) == file.sha256 else {
                throw SpeakerModelAssetError.checksumMismatch(path: file.relativePath)
            }
            let destinationURL = temporaryURL.appending(path: file.relativePath)
            try fileManager.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: destinationURL, options: .atomic)
            receivedByteCount += byteCount
            progress(.init(
                completedByteCount: receivedByteCount,
                totalByteCount: manifest.totalByteCount,
                currentFile: file.relativePath
            ))
        }
        return receivedByteCount
    }

    func verifiedRevisionRootURL() throws -> URL {
        guard try verifyRepository(at: installedRepositoryURL) else {
            throw SpeakerModelAssetError.missingFile(manifest.files[0].relativePath)
        }
        return revisionRootURL
    }

    func onDiskUsage() throws -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: managedRootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
        ) else { return 0 }

        var byteCount: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values.isRegularFile == true {
                byteCount += Int64(values.fileSize ?? 0)
            }
        }
        return byteCount
    }

    func embeddingSpace() -> SpeakerEmbeddingSpace {
        let configuration = FluidAudioSpeakerEmbeddingExtractor.diarizationConfiguration()
        return SpeakerEmbeddingSpace(
            provider: "FluidInference",
            modelName: manifest.repository,
            revision: manifest.revision,
            assetFingerprint: manifest.assetFingerprint,
            fluidAudioVersion: Self.fluidAudioVersion,
            dimensionCount: SpeakerEmbeddingValidation.dimensionCount,
            sampleRate: configuration.segmentation.sampleRate,
            preprocessing: Self.preprocessingDescriptor(configuration: configuration),
            excludesOverlap: configuration.embedding.excludeOverlap,
            normalization: "L2 unit norm",
            similarityDefinition: "cosine dot product"
        )
    }

    static func preprocessingDescriptor(configuration: OfflineDiarizerConfig) -> String {
        let channelDescription = MemoryMappedAudioSampleSource.channelCount == 1
            ? "mono"
            : "\(MemoryMappedAudioSampleSource.channelCount)-channel"
        return "community-1 \(channelDescription) \(MemoryMappedAudioSampleSource.sampleEncoding) "
            + "\(configuration.segmentation.sampleRate)Hz"
    }

    static func downloadURL(for file: SpeakerModelAssetManifest.File, manifest: SpeakerModelAssetManifest) -> URL {
        URL(string: "https://huggingface.co")!
            .appending(path: manifest.repository)
            .appending(path: "resolve")
            .appending(path: manifest.revision)
            .appending(path: file.relativePath)
    }

    private var revisionRootURL: URL {
        managedRootURL.appending(path: manifest.revision, directoryHint: .isDirectory)
    }

    private var installedRepositoryURL: URL {
        revisionRootURL.appending(path: Self.repositoryFolderName, directoryHint: .isDirectory)
    }

    private func verifyRepository(at repositoryURL: URL) throws -> Bool {
        guard fileManager.fileExists(atPath: repositoryURL.path) else { return false }

        var totalByteCount: Int64 = 0
        for file in manifest.files {
            let fileURL = repositoryURL.appending(path: file.relativePath)
            guard fileManager.fileExists(atPath: fileURL.path) else {
                throw SpeakerModelAssetError.missingFile(file.relativePath)
            }
            let data = try Data(contentsOf: fileURL)
            let byteCount = Int64(data.count)
            guard byteCount == file.byteCount else {
                throw SpeakerModelAssetError.byteCountMismatch(
                    path: file.relativePath,
                    expected: file.byteCount,
                    actual: byteCount
                )
            }
            guard Self.sha256(of: data) == file.sha256 else {
                throw SpeakerModelAssetError.checksumMismatch(path: file.relativePath)
            }
            totalByteCount += byteCount
        }

        guard totalByteCount == manifest.totalByteCount else {
            throw SpeakerModelAssetError.totalByteCountMismatch(
                expected: manifest.totalByteCount,
                actual: totalByteCount
            )
        }
        return true
    }

    private static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
