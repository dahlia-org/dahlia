@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import Speech

struct BatchSpeechRecognition: Sendable {
    let startSeconds: TimeInterval
    let endSeconds: TimeInterval
    let text: String
}

protocol BatchSpeechRecognizing: Sendable {
    func recognize(audioURL: URL, locale: Locale) async throws -> [BatchSpeechRecognition]
    func unload() async
}

extension BatchSpeechRecognizing {
    func unload() async {}
}

struct AppleBatchSpeechRecognizer: BatchSpeechRecognizing {
    private let assetPreparer: AppleSpeechAssetPreparer

    init(assetPreparer: AppleSpeechAssetPreparer = AppleSpeechAssetPreparer()) {
        self.assetPreparer = assetPreparer
    }

    func recognize(audioURL: URL, locale: Locale) async throws -> [BatchSpeechRecognition] {
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        try await assetPreparer.prepare(transcriber: transcriber, localeIdentifier: locale.identifier)
        let audioFile = try AVAudioFile(forReading: audioURL)
        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .lingering)
        )
        try await analyzer.prepareToAnalyze(in: audioFile.processingFormat)

        let resultTask = Task<[BatchSpeechRecognition], Error> {
            var recognitions: [BatchSpeechRecognition] = []
            for try await result in transcriber.results where result.isFinal {
                recognitions.append(
                    BatchSpeechRecognition(
                        startSeconds: result.range.start.seconds,
                        endSeconds: result.range.end.seconds,
                        text: String(result.text.characters)
                    )
                )
            }
            return recognitions
        }

        do {
            guard let lastSampleTime = try await analyzer.analyzeSequence(from: audioFile) else {
                throw BatchSpeechTranscriberError.analysisDidNotAdvance
            }
            try await analyzer.finalizeAndFinish(through: lastSampleTime)
            return try await resultTask.value
        } catch {
            await analyzer.cancelAndFinishNow()
            resultTask.cancel()
            _ = try? await resultTask.value
            throw error
        }
    }

    func unload() async {
        await assetPreparer.reset()
    }
}

actor AppleSpeechAssetPreparer {
    typealias PrepareOperation = @Sendable (SpeechTranscriber) async throws -> Void

    private struct Preparation {
        let id: UUID
        let task: Task<Void, Error>
    }

    private let prepareOperation: PrepareOperation
    private var preparedLocaleIdentifiers: Set<String> = []
    private var preparations: [String: Preparation] = [:]

    init(prepareOperation: @escaping PrepareOperation = AppleSpeechAssetPreparer.prepareAsset) {
        self.prepareOperation = prepareOperation
    }

    func prepare(transcriber: SpeechTranscriber, localeIdentifier: String) async throws {
        if preparedLocaleIdentifiers.contains(localeIdentifier) {
            return
        }
        if let preparation = preparations[localeIdentifier] {
            try await Self.waitCancellably(for: preparation.task)
            return
        }

        let id = UUID.v7()
        let prepareOperation = prepareOperation
        let preparationTask = Task {
            try await prepareOperation(transcriber)
        }
        preparations[localeIdentifier] = Preparation(id: id, task: preparationTask)
        Task { [self] in
            let result = await preparationTask.result
            finishPreparation(localeIdentifier: localeIdentifier, id: id, succeeded: result.isSuccess)
        }
        try await Self.waitCancellably(for: preparationTask)
    }

    func reset() {
        for preparation in preparations.values {
            preparation.task.cancel()
        }
        preparations.removeAll()
        preparedLocaleIdentifiers.removeAll()
    }

    private func finishPreparation(localeIdentifier: String, id: UUID, succeeded: Bool) {
        guard preparations[localeIdentifier]?.id == id else { return }
        preparations[localeIdentifier] = nil
        if succeeded {
            preparedLocaleIdentifiers.insert(localeIdentifier)
        }
    }

    private nonisolated static func waitCancellably(for task: Task<Void, Error>) async throws {
        let waiter = SpeechAssetPreparationWaiter()
        Task {
            let result = await task.result
            await waiter.finish(with: result)
        }
        try await waiter.wait()
    }

    private nonisolated static func prepareAsset(transcriber: SpeechTranscriber) async throws {
        let status = await AssetInventory.status(forModules: [transcriber])
        if status < .installed,
           let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
    }
}

private extension Result where Success == Void, Failure == Error {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}

private actor SpeechAssetPreparationWaiter {
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?

    func wait() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if let result {
                    continuation.resume(with: result)
                } else {
                    self.continuation = continuation
                }
            }
        } onCancel: {
            Task { await self.finish(with: .failure(CancellationError())) }
        }
    }

    func finish(with result: Result<Void, Error>) {
        guard self.result == nil else { return }
        self.result = result
        continuation?.resume(with: result)
        continuation = nil
    }
}
