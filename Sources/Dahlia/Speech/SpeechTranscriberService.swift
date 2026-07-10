import AVFoundation
import CoreMedia
import Foundation
import Speech

/// SpeechAnalyzer + SpeechTranscriber によるストリーミング文字起こしサービス。
/// AudioBufferBridge から受け取った AsyncStream<AnalyzerInput> を SpeechAnalyzer に渡し、
/// SpeechTranscriber の結果を保存先に依存しないイベントとして通知する。
actor SpeechTranscriberService {
    typealias EventHandler = @MainActor @Sendable (TranscriptionEvent) async -> Void
    typealias SegmentTranslationHandler = @Sendable (TranscriptSegment) async -> String?

    private enum ServiceError: LocalizedError {
        case notPrepared

        var errorDescription: String? {
            L10n.speechRecognitionNotReady
        }
    }

    private nonisolated static let ignoredConfirmedTexts: Set = [".", "あ"]
    nonisolated let pipelineID: UUID

    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var resultTask: Task<Void, Never>?
    private var finalTranslationTasks: [UUID: Task<Void, Never>] = [:]
    private var bestFormat: AVAudioFormat?
    private var activeSessionId: UUID?
    private var eventHandler: EventHandler?
    private var previewSegmentID: UUID?
    private var hasReportedFailure = false
    private var streamingFailure: Error?

    private let locale: Locale
    private let speakerLabel: String?
    private let translateSegment: SegmentTranslationHandler?
    private let previewTranslationCoordinator: PreviewTranslationCoordinator?

    init(
        pipelineID: UUID = .v7(),
        locale: Locale = Locale(identifier: "ja-JP"),
        speakerLabel: String? = nil,
        translateSegment: SegmentTranslationHandler? = nil
    ) {
        self.pipelineID = pipelineID
        self.locale = locale
        self.speakerLabel = speakerLabel
        self.translateSegment = translateSegment
        if let translateSegment {
            previewTranslationCoordinator = PreviewTranslationCoordinator(translate: translateSegment)
        } else {
            previewTranslationCoordinator = nil
        }
    }

    nonisolated static func normalizedTranscriptText(_ rawText: String) -> String? {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        guard !ignoredConfirmedTexts.contains(text) else { return nil }
        return text
    }

    /// 指定ロケールのモデルがインストール済みか確認し、未インストールならダウンロードする。
    /// 複数パイプライン作成前に一度だけ呼ぶことで二重ダウンロードを回避する。
    static func ensureModelInstalled(locale: Locale) async throws {
        let transcriber = SpeechTranscriber(
            locale: locale,
            preset: .timeIndexedProgressiveTranscription
        )
        let status = await AssetInventory.status(forModules: [transcriber])
        if status < .installed {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        }
    }

    /// SpeechTranscriber と SpeechAnalyzer を初期化し、最適なオーディオフォーマットを取得する。
    /// アセットが未インストールの場合はダウンロードを要求する。
    func prepare() async throws {
        let transcriber = SpeechTranscriber(
            locale: locale,
            preset: .timeIndexedProgressiveTranscription
        )
        self.transcriber = transcriber

        // アセットの状態を確認し、必要ならダウンロードを開始
        let status = await AssetInventory.status(forModules: [transcriber])
        if status < .installed {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        // SpeechAnalyzer に最適なオーディオフォーマットを問い合わせる
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        self.bestFormat = format

        try await analyzer.prepareToAnalyze(in: format)
    }

    /// キャプチャマネージャに渡すべき最適なオーディオフォーマットを返す。
    func targetAudioFormat() -> AVAudioFormat? {
        bestFormat
    }

    /// ストリーミング文字起こしを開始する。
    func startStreaming(
        bridge: AudioBufferBridge,
        recordingStartTime: Date,
        recordingSessionId: UUID,
        onEvent: @escaping EventHandler
    ) async throws {
        guard let analyzer, let transcriber else {
            let error = ServiceError.notPrepared
            await onEvent(.failure(
                sessionId: recordingSessionId,
                pipelineID: pipelineID,
                sourceLabel: speakerLabel,
                message: error.localizedDescription
            ))
            throw error
        }

        activeSessionId = recordingSessionId
        eventHandler = onEvent
        previewSegmentID = nil
        hasReportedFailure = false
        streamingFailure = nil

        do {
            try await analyzer.start(inputSequence: bridge.stream)
        } catch {
            await reportFailure(error)
            clearStreamingContext()
            throw error
        }

        resultTask = Task { [weak self] in
            await self?.consumeResults(
                from: transcriber,
                recordingStartTime: recordingStartTime,
                recordingSessionId: recordingSessionId,
                onEvent: onEvent
            )
        }
    }

    /// ストリーミング文字起こしを停止する。残りのバッファを処理してから終了。
    func stopStreaming() async throws {
        await previewTranslationCoordinator?.cancelPending()
        let runningResultTask = resultTask
        var finalizationError: Error?
        do {
            try await analyzer?.finalizeAndFinishThroughEndOfInput()
        } catch {
            await reportFailure(error)
            finalizationError = error
            runningResultTask?.cancel()
            await analyzer?.cancelAndFinishNow()
        }

        // 結果イテレーションタスクの完了を待機
        await runningResultTask?.value
        resultTask = nil
        // finalize 中に届いた最後の preview が翻訳を開始している可能性がある。
        await previewTranslationCoordinator?.reset()
        await finishFinalTranslations(cancel: false)
        await clearPreview()
        let completionError = finalizationError ?? streamingFailure
        clearStreamingContext()

        if let completionError {
            throw completionError
        }
    }

    /// 即時キャンセル。残りのバッファは破棄する。
    func cancel() async {
        await previewTranslationCoordinator?.cancelPending()
        let runningResultTask = resultTask
        runningResultTask?.cancel()
        await analyzer?.cancelAndFinishNow()
        await runningResultTask?.value
        resultTask = nil
        // 最初の reset 後に結果タスクが登録した preview 翻訳も確実に終了させる。
        await previewTranslationCoordinator?.reset()
        await finishFinalTranslations(cancel: true)
        await clearPreview()
        clearStreamingContext()
    }

    /// 状態をリセットする。
    func reset() async {
        await previewTranslationCoordinator?.cancelPending()
        let runningResultTask = resultTask
        runningResultTask?.cancel()
        await analyzer?.cancelAndFinishNow()
        await runningResultTask?.value
        resultTask = nil
        await previewTranslationCoordinator?.reset()
        await finishFinalTranslations(cancel: true)
        await clearPreview()
        clearStreamingContext()
        analyzer = nil
        transcriber = nil
        bestFormat = nil
    }

    private func consumeResults(
        from transcriber: SpeechTranscriber,
        recordingStartTime: Date,
        recordingSessionId: UUID,
        onEvent: @escaping EventHandler
    ) async {
        do {
            for try await result in transcriber.results {
                guard !Task.isCancelled else { return }

                let label = speakerLabel
                guard let text = Self.normalizedTranscriptText(String(result.text.characters)) else {
                    if result.isFinal {
                        await previewTranslationCoordinator?.cancelPending()
                        previewSegmentID = nil
                        await onEvent(.clearPreview(sessionId: recordingSessionId, sourceLabel: label))
                    }
                    continue
                }

                let startSeconds = result.range.start.seconds
                let endSeconds = result.range.end.seconds
                let segment = TranscriptSegment(
                    id: segmentID(forFinalResult: result.isFinal),
                    sessionId: recordingSessionId,
                    startTime: recordingStartTime.addingTimeInterval(startSeconds.isFinite ? startSeconds : 0),
                    endTime: recordingStartTime.addingTimeInterval(endSeconds.isFinite ? endSeconds : 0),
                    text: text,
                    isConfirmed: result.isFinal,
                    speakerLabel: label
                )

                if result.isFinal {
                    await previewTranslationCoordinator?.cancelPending()
                    previewSegmentID = nil
                    await onEvent(.clearPreview(sessionId: recordingSessionId, sourceLabel: label))
                    await onEvent(.finalized(segment))

                    startFinalTranslation(
                        for: segment,
                        recordingSessionId: recordingSessionId,
                        onEvent: onEvent
                    )
                } else {
                    await onEvent(.preview(segment))
                    await previewTranslationCoordinator?.unconfirmedSegmentDidChange(segment) { segmentID, translatedText in
                        await onEvent(
                            .translation(
                                sessionId: recordingSessionId,
                                segmentID: segmentID,
                                translatedText: translatedText
                            )
                        )
                    }
                }
            }
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            await reportFailure(error)
        }
    }

    private func segmentID(forFinalResult isFinal: Bool) -> UUID {
        if let previewSegmentID {
            return previewSegmentID
        }

        let id = UUID.v7()
        if !isFinal {
            previewSegmentID = id
        }
        return id
    }

    private func reportFailure(_ error: Error) async {
        if streamingFailure == nil {
            streamingFailure = error
        }
        guard !hasReportedFailure,
              let activeSessionId,
              let eventHandler else { return }
        hasReportedFailure = true
        await eventHandler(.failure(
            sessionId: activeSessionId,
            pipelineID: pipelineID,
            sourceLabel: speakerLabel,
            message: error.localizedDescription
        ))
    }

    private func startFinalTranslation(
        for segment: TranscriptSegment,
        recordingSessionId: UUID,
        onEvent: @escaping EventHandler
    ) {
        guard let translateSegment else { return }
        let taskID = UUID.v7()
        finalTranslationTasks[taskID] = Task { [weak self] in
            let translatedText = await translateSegment(segment)
            if !Task.isCancelled {
                await onEvent(.translation(
                    sessionId: recordingSessionId,
                    segmentID: segment.id,
                    translatedText: translatedText
                ))
            }
            await self?.finalTranslationDidFinish(taskID: taskID)
        }
    }

    private func finalTranslationDidFinish(taskID: UUID) {
        finalTranslationTasks[taskID] = nil
    }

    private func finishFinalTranslations(cancel: Bool) async {
        while !finalTranslationTasks.isEmpty {
            let tasks = Array(finalTranslationTasks.values)
            finalTranslationTasks.removeAll()
            if cancel {
                tasks.forEach { $0.cancel() }
            }
            for task in tasks {
                await task.value
            }
        }
    }

    private func clearPreview() async {
        guard let activeSessionId,
              let eventHandler else { return }
        await eventHandler(.clearPreview(sessionId: activeSessionId, sourceLabel: speakerLabel))
        previewSegmentID = nil
    }

    private func clearStreamingContext() {
        activeSessionId = nil
        eventHandler = nil
        previewSegmentID = nil
        hasReportedFailure = false
        streamingFailure = nil
    }
}
