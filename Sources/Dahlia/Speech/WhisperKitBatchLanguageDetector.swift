import DahliaRuntimeSupport
import Foundation
import os
import WhisperKit

actor WhisperKitBatchLanguageDetector: BatchLanguageDetecting {
    private static let signposter = OSSignposter(subsystem: "com.dahlia", category: "BatchTranscription")
    static let modelFolderName = "openai_whisper-tiny"
    static let modelRepository = HubApiWrapper.Repo(id: "argmaxinc/whisperkit-coreml")
    static let modelRevision = "97a5bf9bbc74c7d9c12c755d04dea59e672e3808"
    static let tokenizerRepository = HubApiWrapper.Repo(id: "openai/whisper-tiny")
    static let tokenizerRevision = "169d4a4341b33bc18d8881c4b69c2e104e1cc0af"
    static let modelRelativePaths = [
        "AudioEncoder.mlmodelc/analytics/coremldata.bin",
        "AudioEncoder.mlmodelc/coremldata.bin",
        "AudioEncoder.mlmodelc/metadata.json",
        "AudioEncoder.mlmodelc/model.mil",
        "AudioEncoder.mlmodelc/model.mlmodel",
        "AudioEncoder.mlmodelc/weights/weight.bin",
        "MelSpectrogram.mlmodelc/analytics/coremldata.bin",
        "MelSpectrogram.mlmodelc/coremldata.bin",
        "MelSpectrogram.mlmodelc/metadata.json",
        "MelSpectrogram.mlmodelc/model.mil",
        "MelSpectrogram.mlmodelc/weights/weight.bin",
        "TextDecoder.mlmodelc/analytics/coremldata.bin",
        "TextDecoder.mlmodelc/coremldata.bin",
        "TextDecoder.mlmodelc/metadata.json",
        "TextDecoder.mlmodelc/model.mil",
        "TextDecoder.mlmodelc/model.mlmodel",
        "TextDecoder.mlmodelc/weights/weight.bin",
        "config.json",
        "generation_config.json",
    ]
    static let tokenizerRelativePaths = [
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

    private let modelDownloadBaseURL: URL
    private let operationLimiter = BatchTranscriptionConcurrencyLimiter(limit: 1)
    private var whisperKit: WhisperKit?
    private var restrictedTextDecoder: CandidateRestrictedTextDecoder?
    private var modelsAreLoaded = false

    init(
        modelDownloadBaseURL: URL = DahliaApplicationSupport.currentDirectoryURL
            .appending(path: "Models", directoryHint: .isDirectory)
            .appending(path: "WhisperKit", directoryHint: .isDirectory)
    ) {
        self.modelDownloadBaseURL = modelDownloadBaseURL
    }

    func detectLanguage(
        audioURL: URL,
        allowedLanguageIdentifiers: Set<String>?
    ) async throws -> BatchLanguageDetectionOutcome {
        try await operationLimiter.perform { [self] in
            try await detectLanguageSerially(
                audioURL: audioURL,
                allowedLanguageIdentifiers: allowedLanguageIdentifiers
            )
        }
    }

    private func detectLanguageSerially(
        audioURL: URL,
        allowedLanguageIdentifiers: Set<String>?
    ) async throws -> BatchLanguageDetectionOutcome {
        let whisperKit: WhisperKit
        do {
            whisperKit = try await loadedWhisperKit()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw BatchLanguageDetectorError.modelPreparationFailed
        }

        do {
            let detectionState = Self.signposter.beginInterval("Detect language")
            defer { Self.signposter.endInterval("Detect language", detectionState) }
            restrictedTextDecoder?.allowedLanguageIdentifiers = allowedLanguageIdentifiers
            let result = try await whisperKit.detectLanguage(audioPath: audioURL.path)
            return .detected(
                languageIdentifier: result.language,
                logProbability: result.langProbs[result.language]
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw BatchLanguageDetectorError.detectionFailed
        }
    }

    func unload() async {
        await operationLimiter.performWithoutCancellation { [self] in
            await unloadModels()
        }
    }

    private func unloadModels() async {
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
        let restrictedTextDecoder = CandidateRestrictedTextDecoder()
        let whisperKit = try await WhisperKit(
            WhisperKitConfig(
                modelFolder: modelFolder.path,
                tokenizerFolder: tokenizerFolder,
                textDecoder: restrictedTextDecoder,
                verbose: false,
                prewarm: false,
                load: true,
                download: false
            )
        )
        self.restrictedTextDecoder = restrictedTextDecoder
        self.whisperKit = whisperKit
        modelsAreLoaded = true
        return whisperKit
    }

    private func prepareModelFolder() async throws -> URL {
        let hub = HubApiWrapper(downloadBase: modelDownloadBaseURL)
        let repositoryFolder = hub.localRepoLocation(Self.modelRepository)
        let modelFolder = repositoryFolder.appending(path: Self.modelFolderName, directoryHint: .isDirectory)
        if Self.hasPinnedModel(repositoryFolder: repositoryFolder) {
            return modelFolder
        }

        _ = try await hub.snapshot(
            from: Self.modelRepository,
            revision: Self.modelRevision,
            matching: ["\(Self.modelFolderName)/*"]
        )
        try Task.checkCancellation()
        guard Self.hasPinnedModel(repositoryFolder: repositoryFolder) else {
            throw BatchLanguageDetectorError.modelPreparationFailed
        }
        return modelFolder
    }

    private func prepareTokenizerFolder() async throws -> URL {
        let hub = HubApiWrapper(downloadBase: modelDownloadBaseURL)
        let tokenizerFolder = hub.localRepoLocation(Self.tokenizerRepository)
        if Self.hasPinnedTokenizer(repositoryFolder: tokenizerFolder) {
            return tokenizerFolder
        }

        _ = try await hub.snapshot(
            from: Self.tokenizerRepository,
            revision: Self.tokenizerRevision,
            matching: Self.tokenizerRelativePaths
        )
        try Task.checkCancellation()
        guard Self.hasPinnedTokenizer(repositoryFolder: tokenizerFolder) else {
            throw BatchLanguageDetectorError.modelPreparationFailed
        }
        return tokenizerFolder
    }

    static func hasPinnedModel(repositoryFolder: URL) -> Bool {
        hasPinnedFiles(
            repositoryFolder: repositoryFolder,
            relativePaths: modelRelativePaths.map { "\(modelFolderName)/\($0)" },
            revision: modelRevision
        )
    }

    static func hasPinnedTokenizer(repositoryFolder: URL) -> Bool {
        hasPinnedFiles(
            repositoryFolder: repositoryFolder,
            relativePaths: tokenizerRelativePaths,
            revision: tokenizerRevision
        )
    }

    private static func hasPinnedFiles(
        repositoryFolder: URL,
        relativePaths: [String],
        revision: String
    ) -> Bool {
        relativePaths.allSatisfy { relativePath in
            FileManager.default.fileExists(atPath: repositoryFolder.appending(path: relativePath).path)
                && metadataRevision(repositoryFolder: repositoryFolder, relativePath: relativePath) == revision
        }
    }

    private static func metadataRevision(repositoryFolder: URL, relativePath: String) -> String? {
        let metadataURL = repositoryFolder
            .appending(path: ".cache/huggingface/download", directoryHint: .isDirectory)
            .appending(path: "\(relativePath).metadata")
        guard let contents = try? String(contentsOf: metadataURL, encoding: .utf8) else { return nil }
        return contents.split(whereSeparator: \.isNewline).first.map(String.init)
    }
}
