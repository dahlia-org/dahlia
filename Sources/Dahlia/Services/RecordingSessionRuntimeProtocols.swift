@preconcurrency import AVFoundation
import Foundation
import GRDB

typealias AudioCaptureUnexpectedStopHandler = @Sendable (Error?) -> Void
typealias ProgressiveTranscriptionEventHandler = @Sendable (TranscriptionEvent) async -> Void
typealias ProgressiveSegmentTranslationHandler = @Sendable (TranscriptSegment) async -> String?

/// 1音源につき1つだけ生成される、物理 capture の実行単位。
protocol AudioCaptureSession: Sendable {
    func start() async throws
    func stop() async throws
}

/// 実デバイス capture とテスト用 fake を差し替えるための生成境界。
protocol AudioCaptureSessionFactory: Sendable {
    func requestPermission(for source: RecordingAudioSource) async -> Bool

    func makeSession(
        for pipeline: AudioSourcePipeline,
        onUnexpectedStop: @escaping AudioCaptureUnexpectedStopHandler
    ) -> any AudioCaptureSession
}

/// SpeechTranscriberService と AudioBufferBridge を1つの認識処理として扱う実行単位。
protocol ProgressiveRecognitionSession: Sendable {
    var pipelineID: UUID { get }
    var liveConsumer: AudioFrameRouter.LiveConsumer { get }

    func start(
        recordingStartTime: Date,
        recordingSessionId: UUID,
        onEvent: @escaping ProgressiveTranscriptionEventHandler
    ) async throws

    /// router を drain した後、入力を閉じて最終結果まで処理する。finalize に失敗した場合は送出する。
    func finish() async throws

    /// 一時字幕の切り離しや abort 時に、残りの入力を破棄する。
    func cancel() async
}

/// progressive recognizer のモデル準備と session 生成を差し替える境界。
protocol ProgressiveRecognitionSessionFactory: Sendable {
    func prepareModel(locale: Locale) async throws

    func prepareSession(
        locale: Locale,
        source: RecordingAudioSource,
        sourceFormat: AVAudioFormat?,
        bufferingMode: AudioBufferBridge.BufferingMode,
        translateSegment: ProgressiveSegmentTranslationHandler?
    ) async throws -> PreparedProgressiveRecognitionSession
}

/// 音源別CAFとlocale rangeを管理するバッチ録音の実行単位。
protocol BatchRecordingSession: AnyObject, Sendable {
    var targetFormat: AVAudioFormat { get }

    func prepare(source: RecordingAudioSource) async throws
    func beginRangeConsumer(
        source: RecordingAudioSource,
        locale: Locale,
        at date: Date,
        continuingFromActiveRange: Bool
    ) async throws -> BatchRecordingConsumerAttachment
    func rotateRanges(
        _ origins: [BatchRecordingRangeOrigin],
        locale: Locale
    ) async throws -> [RecordingAudioSource: BatchRecordingRangeOrigin]
    func endRangeForReconfiguration(source: RecordingAudioSource) async throws
    func finish() async throws
    func cancelAndDelete() async
}

/// バッチ録音の実装を、DBや保存先を含めて生成する境界。
protocol BatchRecordingSessionFactory: Sendable {
    func makeSession(
        dbQueue: DatabaseQueue,
        managedRootURL: URL,
        meetingId: UUID,
        recordingSessionId: UUID,
        recordingStartTime: Date,
        sampleRate: Double
    ) throws -> any BatchRecordingSession
}

/// バッチ文字起こしのqueue実装をcontrollerから注入可能にする境界。
protocol BatchTranscriptionScheduling: Sendable {
    func enqueue(sessionId: UUID) async
    func recordRecordingFailure(sessionId: UUID, message: String) async
}
