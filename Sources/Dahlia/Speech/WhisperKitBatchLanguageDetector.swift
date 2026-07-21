import DahliaRuntimeSupport
import Foundation
import WhisperKit

actor WhisperKitBatchLanguageDetector: BatchLanguageDetecting {
    static let modelFolderName = "openai_whisper-tiny"
    static let modelRepository = HubApiWrapper.Repo(id: "argmaxinc/whisperkit-coreml")
    static let modelRevision = "97a5bf9bbc74c7d9c12c755d04dea59e672e3808"
    static let tokenizerRepository = HubApiWrapper.Repo(id: "openai/whisper-tiny")
    static let tokenizerRevision = "169d4a4341b33bc18d8881c4b69c2e104e1cc0af"

    private let modelDownloadBaseURL: URL
    private var whisperKit: WhisperKit?
    private var modelsAreLoaded = false

    init(
        modelDownloadBaseURL: URL = DahliaApplicationSupport.currentDirectoryURL
            .appending(path: "Models", directoryHint: .isDirectory)
            .appending(path: "WhisperKit", directoryHint: .isDirectory)
    ) {
        self.modelDownloadBaseURL = modelDownloadBaseURL
    }

    func detectLanguage(audioURL: URL) async throws -> String {
        let whisperKit: WhisperKit
        do {
            whisperKit = try await loadedWhisperKit()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw BatchLanguageDetectorError.modelPreparationFailed
        }

        do {
            let result = try await whisperKit.detectLanguage(audioPath: audioURL.path)
            return result.language
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw BatchLanguageDetectorError.detectionFailed
        }
    }

    func unload() async {
        await whisperKit?.unloadModels()
        modelsAreLoaded = false
    }

    private func loadedWhisperKit() async throws -> WhisperKit {
        if let whisperKit {
            if !modelsAreLoaded {
                try await whisperKit.loadModels()
                modelsAreLoaded = true
            }
            return whisperKit
        }
        try FileManager.default.createDirectory(
            at: modelDownloadBaseURL,
            withIntermediateDirectories: true
        )
        let modelFolder = try await prepareModelFolder()
        let tokenizerFolder = try await prepareTokenizerFolder()
        let whisperKit = try await WhisperKit(
            WhisperKitConfig(
                modelFolder: modelFolder.path,
                tokenizerFolder: tokenizerFolder,
                verbose: false,
                prewarm: false,
                load: true,
                download: false
            )
        )
        self.whisperKit = whisperKit
        modelsAreLoaded = true
        return whisperKit
    }

    private func prepareModelFolder() async throws -> URL {
        let hub = HubApiWrapper(downloadBase: modelDownloadBaseURL)
        let repositoryFolder = hub.localRepoLocation(Self.modelRepository)
        let modelFolder = repositoryFolder.appending(path: Self.modelFolderName, directoryHint: .isDirectory)
        if hasPinnedModel(at: modelFolder, repositoryFolder: repositoryFolder) {
            return modelFolder
        }

        _ = try await hub.snapshot(
            from: Self.modelRepository,
            revision: Self.modelRevision,
            matching: ["\(Self.modelFolderName)/*"]
        )
        try Task.checkCancellation()
        guard hasPinnedModel(at: modelFolder, repositoryFolder: repositoryFolder) else {
            throw BatchLanguageDetectorError.modelPreparationFailed
        }
        return modelFolder
    }

    private func prepareTokenizerFolder() async throws -> URL {
        let hub = HubApiWrapper(downloadBase: modelDownloadBaseURL)
        let tokenizerFolder = hub.localRepoLocation(Self.tokenizerRepository)
        if hasPinnedTokenizer(at: tokenizerFolder) {
            return tokenizerFolder
        }

        _ = try await hub.snapshot(
            from: Self.tokenizerRepository,
            revision: Self.tokenizerRevision,
            matching: [
                "added_tokens.json",
                "config.json",
                "merges.txt",
                "normalizer.json",
                "preprocessor_config.json",
                "special_tokens_map.json",
                "tokenizer.json",
                "tokenizer_config.json",
                "vocab.json",
            ]
        )
        try Task.checkCancellation()
        guard hasPinnedTokenizer(at: tokenizerFolder) else {
            throw BatchLanguageDetectorError.modelPreparationFailed
        }
        return tokenizerFolder
    }

    private func hasPinnedModel(at modelFolder: URL, repositoryFolder: URL) -> Bool {
        let requiredPaths = [
            "AudioEncoder.mlmodelc/coremldata.bin",
            "MelSpectrogram.mlmodelc/coremldata.bin",
            "TextDecoder.mlmodelc/coremldata.bin",
        ]
        guard requiredPaths.allSatisfy({
            FileManager.default.fileExists(atPath: modelFolder.appending(path: $0).path)
        }) else { return false }
        return metadataRevision(
            repositoryFolder: repositoryFolder,
            relativePath: "\(Self.modelFolderName)/config.json"
        ) == Self.modelRevision
    }

    private func hasPinnedTokenizer(at tokenizerFolder: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: tokenizerFolder.appending(path: "tokenizer.json").path) else {
            return false
        }
        return metadataRevision(
            repositoryFolder: tokenizerFolder,
            relativePath: "tokenizer.json"
        ) == Self.tokenizerRevision
    }

    private func metadataRevision(repositoryFolder: URL, relativePath: String) -> String? {
        let metadataURL = repositoryFolder
            .appending(path: ".cache/huggingface/download", directoryHint: .isDirectory)
            .appending(path: "\(relativePath).metadata")
        guard let contents = try? String(contentsOf: metadataURL, encoding: .utf8) else { return nil }
        return contents.split(whereSeparator: \.isNewline).first.map(String.init)
    }
}
