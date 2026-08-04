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
    func recognize(audioSlices: [BatchSpeechAudioSlice], locale: Locale) async throws -> [BatchSpeechRecognition]
    func recognize(
        audioSlices: [BatchSpeechAudioSlice],
        locale: Locale,
        onSliceConsumed: @escaping @Sendable (Int) async -> Void
    ) async throws -> [BatchSpeechRecognition]
    func unload() async
}

extension BatchSpeechRecognizing {
    func recognize(audioSlices _: [BatchSpeechAudioSlice], locale _: Locale) async throws -> [BatchSpeechRecognition] {
        throw BatchSpeechTranscriberError.invalidAudioRange
    }

    func recognize(
        audioSlices: [BatchSpeechAudioSlice],
        locale: Locale,
        onSliceConsumed: @escaping @Sendable (Int) async -> Void
    ) async throws -> [BatchSpeechRecognition] {
        let recognitions = try await recognize(audioSlices: audioSlices, locale: locale)
        for sliceIndex in audioSlices.indices {
            await onSliceConsumed(sliceIndex)
        }
        return recognitions
    }

    func unload() async {}
}

struct AppleBatchSpeechRecognizer: BatchSpeechRecognizing {
    typealias StallTimeoutProvider = @Sendable () async -> BatchTranscriptionStallTimeout

    private let assetPreparer: AppleSpeechAssetPreparer
    private let stallTimeoutProvider: StallTimeoutProvider
    private let watchdogClock: any BatchSpeechWatchdogClock

    init(
        assetPreparer: AppleSpeechAssetPreparer = AppleSpeechAssetPreparer(),
        stallTimeoutProvider: @escaping StallTimeoutProvider = {
            await MainActor.run { AppSettings.shared.batchTranscriptionStallTimeout }
        },
        watchdogClock: any BatchSpeechWatchdogClock = ContinuousBatchSpeechWatchdogClock()
    ) {
        self.assetPreparer = assetPreparer
        self.stallTimeoutProvider = stallTimeoutProvider
        self.watchdogClock = watchdogClock
    }

    func recognize(audioURL: URL, locale: Locale) async throws -> [BatchSpeechRecognition] {
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        try await assetPreparer.prepare(transcriber: transcriber, localeIdentifier: locale.identifier)
        let audioFile = try AVAudioFile(forReading: audioURL)
        return try await recognize(
            transcriber: transcriber,
            audioFormat: audioFile.processingFormat
        ) { analyzer, recordProgress in
            await recordProgress()
            return try await analyzer.analyzeSequence(from: audioFile)
        }
    }

    func recognize(audioSlices: [BatchSpeechAudioSlice], locale: Locale) async throws -> [BatchSpeechRecognition] {
        try await recognize(audioSlices: audioSlices, locale: locale, onSliceConsumed: { _ in })
    }

    func recognize(
        audioSlices: [BatchSpeechAudioSlice],
        locale: Locale,
        onSliceConsumed: @escaping @Sendable (Int) async -> Void
    ) async throws -> [BatchSpeechRecognition] {
        guard let firstSlice = audioSlices.first else {
            throw BatchSpeechTranscriberError.invalidAudioRange
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        try await assetPreparer.prepare(transcriber: transcriber, localeIdentifier: locale.identifier)
        let sourceFormat = try {
            let firstFile = try AVAudioFile(forReading: firstSlice.audioURL)
            return firstFile.processingFormat
        }()
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber],
            considering: sourceFormat
        ) else {
            throw BatchSpeechTranscriberError.audioFormatUnavailable
        }
        return try await recognize(
            transcriber: transcriber,
            audioFormat: analyzerFormat
        ) { analyzer, recordProgress in
            let inputSequence = try BatchSpeechAnalyzerInputSequence(
                slices: audioSlices,
                sourceFormat: sourceFormat,
                analyzerFormat: analyzerFormat
            ) { sliceIndex in
                await recordProgress()
                await onSliceConsumed(sliceIndex)
            }
            await recordProgress()
            return try await analyzer.analyzeSequence(inputSequence)
        }
    }

    private func recognize(
        transcriber: SpeechTranscriber,
        audioFormat: AVAudioFormat,
        analyze: @escaping @Sendable (
            SpeechAnalyzer,
            @escaping @Sendable () async -> Void
        ) async throws -> CMTime?
    ) async throws -> [BatchSpeechRecognition] {
        let stallTimeout = await stallTimeoutProvider()
        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .lingering)
        )
        try await analyzer.prepareToAnalyze(in: audioFormat)
        let watchdog = BatchSpeechAnalysisWatchdog(
            timeout: stallTimeout.duration,
            clock: watchdogClock
        ) {
            await analyzer.cancelAndFinishNow()
        }
        await watchdog.start()

        let resultTask = Task<[BatchSpeechRecognition], Error> {
            var recognitions: [BatchSpeechRecognition] = []
            for try await result in transcriber.results {
                await watchdog.recordProgress()
                guard result.isFinal else { continue }
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
            let recordProgress: @Sendable () async -> Void = {
                await watchdog.recordProgress()
            }
            guard let lastSampleTime = try await analyze(analyzer, recordProgress) else {
                throw BatchSpeechTranscriberError.analysisDidNotAdvance
            }
            try await throwIfAnalysisStalled(watchdog: watchdog, timeout: stallTimeout)
            try await analyzer.finalizeAndFinish(through: lastSampleTime)
            let recognitions = try await resultTask.value
            try await throwIfAnalysisStalled(watchdog: watchdog, timeout: stallTimeout)
            await watchdog.stop()
            return recognitions
        } catch {
            let didTimeOut = await watchdog.didTimeOut
            await watchdog.stop()
            resultTask.cancel()
            if didTimeOut {
                throw BatchSpeechTranscriberError.analysisStalled(minutes: stallTimeout.rawValue)
            }
            await analyzer.cancelAndFinishNow()
            _ = try? await resultTask.value
            throw error
        }
    }

    private func throwIfAnalysisStalled(
        watchdog: BatchSpeechAnalysisWatchdog,
        timeout: BatchTranscriptionStallTimeout
    ) async throws {
        if await watchdog.didTimeOut {
            throw BatchSpeechTranscriberError.analysisStalled(minutes: timeout.rawValue)
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
