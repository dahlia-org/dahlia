@preconcurrency import AVFoundation
import CoreAudio
import CoreMedia
import Foundation
import GRDB

/// 物理capture、progressive認識、CAF録音をセッション単位で所有し、ライフサイクルを直列化する。
actor RecordingSessionController {
    typealias EventHandler = ProgressiveTranscriptionEventHandler
    typealias RuntimeFailureHandler = @MainActor @Sendable (
        _ source: RecordingAudioSource?,
        _ message: String,
        _ isFatal: Bool
    ) -> Void

    struct SourceConfiguration: Equatable {
        let source: RecordingAudioSource
        let captureDeviceID: AudioDeviceID?
        let captureBufferSize: AVAudioFrameCount

        init(
            source: RecordingAudioSource,
            captureDeviceID: AudioDeviceID? = nil,
            captureBufferSize: AVAudioFrameCount = 4096
        ) {
            self.source = source
            self.captureDeviceID = captureDeviceID
            self.captureBufferSize = captureBufferSize
        }
    }

    struct PreparationRequest {
        let sessionId: UUID
        let startedAt: Date
        let plan: TranscriptionSessionPlan
        let locale: Locale
        let sources: [SourceConfiguration]
        let dbQueue: DatabaseQueue?
        let meetingId: UUID?
        let batchSampleRate: Double?
        let managedAudioRootURL: URL
        let translateSegment: ProgressiveSegmentTranslationHandler?
        let batchScheduler: (any BatchTranscriptionScheduling)?

        init(
            sessionId: UUID,
            startedAt: Date,
            plan: TranscriptionSessionPlan,
            locale: Locale,
            sources: [SourceConfiguration],
            dbQueue: DatabaseQueue? = nil,
            meetingId: UUID? = nil,
            batchSampleRate: Double? = nil,
            managedAudioRootURL: URL = BatchAudioStorage.managedRootURL,
            translateSegment: ProgressiveSegmentTranslationHandler? = nil,
            batchScheduler: (any BatchTranscriptionScheduling)? = nil
        ) {
            self.sessionId = sessionId
            self.startedAt = startedAt
            self.plan = plan
            self.locale = locale
            self.sources = sources
            self.dbQueue = dbQueue
            self.meetingId = meetingId
            self.batchSampleRate = batchSampleRate
            self.managedAudioRootURL = managedAudioRootURL
            self.translateSegment = translateSegment
            self.batchScheduler = batchScheduler
        }
    }

    struct StopResult: Equatable {
        let sessionId: UUID
        let finalMode: TranscriptionMode
        let batchRecordingSucceeded: Bool
        let batchFailureMessage: String?
    }

    struct ResourceCounts: Equatable {
        let captures: Int
        let recognizers: Int
        let batchRecorders: Int
        let batchSchedulers: Int
    }

    struct Snapshot: Equatable {
        let sessionId: UUID
        let startedAt: Date
        var plan: TranscriptionSessionPlan
        var localeIdentifier: String
        var enabledSources: Set<RecordingAudioSource>
    }

    enum State: Equatable {
        case idle
        case prepared(Snapshot)
        case capturing(Snapshot)
        case stopping(Snapshot)
    }

    struct PreparedSource {
        let configuration: SourceConfiguration
        let recognition: PreparedProgressiveRecognitionSession?
    }

    private struct Preparation {
        let sources: [PreparedSource]
        let locale: Locale
    }

    struct PendingRecognitionStart {
        let source: RecordingAudioSource
        let sessionId: UUID
        var failureMessage: String?
    }

    struct SourceRuntime {
        let id: UUID
        let pipeline: AudioSourcePipeline
        let capture: any AudioCaptureSession
        var recognition: (any ProgressiveRecognitionSession)?
        var batchRangeOrigin: BatchRecordingRangeOrigin?
    }

    let captureFactory: any AudioCaptureSessionFactory
    let recognitionFactory: any ProgressiveRecognitionSessionFactory
    private let batchRecordingFactory: any BatchRecordingSessionFactory

    private(set) var state: State = .idle
    private var preparation: Preparation?
    var sourceRuntimes: [RecordingAudioSource: SourceRuntime] = [:]
    var sourceRuntimeGenerations: [RecordingAudioSource: UUID] = [:]
    var pendingRecognitionStarts: [UUID: PendingRecognitionStart] = [:]
    var batchRecording: (any BatchRecordingSession)?
    var batchEventTask: Task<Void, Never>?
    private var batchScheduler: (any BatchTranscriptionScheduling)?
    var onEvent: EventHandler?
    var onRuntimeFailure: RuntimeFailureHandler?
    var currentLocale: Locale?
    var batchRuntimeFailureMessage: String?

    init(
        captureFactory: any AudioCaptureSessionFactory = DefaultAudioCaptureSessionFactory(),
        recognitionFactory: any ProgressiveRecognitionSessionFactory = DefaultProgressiveRecognitionSessionFactory(),
        batchRecordingFactory: any BatchRecordingSessionFactory = DefaultBatchRecordingSessionFactory()
    ) {
        self.captureFactory = captureFactory
        self.recognitionFactory = recognitionFactory
        self.batchRecordingFactory = batchRecordingFactory
    }

    /// permission/model/sinkを準備する。物理captureはまだ開始しない。
    func prepare(
        _ request: PreparationRequest,
        onEvent: @escaping EventHandler,
        onRuntimeFailure: @escaping RuntimeFailureHandler
    ) async throws {
        guard case .idle = state else {
            throw RecordingSessionControllerError.sessionAlreadyActive
        }
        let configurations = Self.uniqueSortedConfigurations(request.sources)
        guard !configurations.isEmpty else {
            throw RecordingSessionControllerError.noAudioSource
        }

        var preparedRecognitions: [PreparedProgressiveRecognitionSession] = []
        do {
            for configuration in configurations {
                guard await captureFactory.requestPermission(for: configuration.source) else {
                    throw Self.permissionError(for: configuration.source)
                }
            }

            var recognitionModelIsAvailable = request.plan.requiresLiveRecognition
            if request.plan.requiresLiveRecognition {
                do {
                    try await recognitionFactory.prepareModel(locale: request.locale)
                } catch {
                    guard request.plan.finalMode == .batch else { throw error }
                    recognitionModelIsAvailable = false
                    await onRuntimeFailure(nil, error.localizedDescription, false)
                }
            }

            if request.plan.recordsBatchAudio {
                guard let dbQueue = request.dbQueue,
                      let meetingId = request.meetingId,
                      let sampleRate = request.batchSampleRate else {
                    throw RecordingSessionControllerError.invalidBatchConfiguration
                }
                batchRecording = try batchRecordingFactory.makeSession(
                    dbQueue: dbQueue,
                    managedRootURL: request.managedAudioRootURL,
                    meetingId: meetingId,
                    recordingSessionId: request.sessionId,
                    recordingStartTime: request.startedAt,
                    sampleRate: sampleRate
                )
            }

            let batchFormat = batchRecording?.targetFormat
            var preparedSources: [PreparedSource] = []
            for configuration in configurations {
                let recognition: PreparedProgressiveRecognitionSession?
                if recognitionModelIsAvailable {
                    do {
                        recognition = try await recognitionFactory.prepareSession(
                            locale: request.locale,
                            source: configuration.source,
                            sourceFormat: request.plan.recordsBatchAudio ? batchFormat : nil,
                            bufferingMode: request.plan.recordsBatchAudio
                                ? .lowLatency(maximumInputCount: 64)
                                : .lossless,
                            translateSegment: request.translateSegment
                        )
                        if let recognition {
                            preparedRecognitions.append(recognition)
                        }
                    } catch {
                        guard request.plan.finalMode == .batch else { throw error }
                        recognition = nil
                        await onRuntimeFailure(configuration.source, error.localizedDescription, false)
                    }
                } else {
                    recognition = nil
                }
                preparedSources.append(PreparedSource(
                    configuration: configuration,
                    recognition: recognition
                ))
            }

            let snapshot = Snapshot(
                sessionId: request.sessionId,
                startedAt: request.startedAt,
                plan: request.plan,
                localeIdentifier: request.locale.identifier,
                enabledSources: Set(configurations.map(\.source))
            )
            preparation = Preparation(
                sources: preparedSources,
                locale: request.locale
            )
            batchScheduler = request.batchScheduler
            self.onEvent = onEvent
            self.onRuntimeFailure = onRuntimeFailure
            currentLocale = request.locale
            state = .prepared(snapshot)
            startBatchEventMonitoring()
        } catch {
            for recognition in preparedRecognitions {
                await recognition.session.cancel()
            }
            await cleanupPreparedResources()
            throw error
        }
    }

    /// persistence作成後に、consumer接続と物理capture開始を行う。
    func startPrepared() async throws -> Snapshot {
        guard case let .prepared(snapshot) = state,
              let preparation else {
            throw RecordingSessionControllerError.sessionNotPrepared
        }
        state = .capturing(snapshot)

        do {
            for preparedSource in preparation.sources {
                try await startPreparedSource(
                    preparedSource,
                    locale: preparation.locale,
                    snapshot: snapshot
                )
            }
            await batchRecording?.freezeRequiredSources()
            guard case let .capturing(currentSnapshot) = state,
                  currentSnapshot.sessionId == snapshot.sessionId else {
                throw RecordingSessionControllerError.sessionNotActive
            }
            self.preparation = nil
            return currentSnapshot
        } catch {
            if case let .capturing(currentSnapshot) = state,
               currentSnapshot.sessionId == snapshot.sessionId {
                await cleanupActiveResources(cancelRecognition: true, deleteBatchRecording: true)
                await cleanupPreparedResources()
                resetState()
            }
            throw error
        }
    }

    /// capture → router drain → live finalize → CAF finalize の順で停止する。
    func stop() async throws -> StopResult {
        guard case let .capturing(snapshot) = state else {
            throw RecordingSessionControllerError.sessionNotActive
        }
        state = .stopping(snapshot)

        for source in Self.sortedSources(sourceRuntimes.keys) {
            try? await sourceRuntimes[source]?.capture.stop()
        }
        for runtime in sourceRuntimes.values {
            runtime.pipeline.router.removeAllConsumers()
        }
        for runtime in sourceRuntimes.values {
            await runtime.pipeline.router.waitUntilIdle()
        }
        var recognitionFailure: Error?
        for source in Self.sortedSources(sourceRuntimes.keys) {
            guard let recognition = sourceRuntimes[source]?.recognition else { continue }
            do {
                try await recognition.finish()
            } catch {
                if recognitionFailure == nil {
                    recognitionFailure = error
                }
                await onRuntimeFailure?(
                    source,
                    error.localizedDescription,
                    snapshot.plan.finalMode == .realtime
                )
            }
        }

        var batchSucceeded = batchRuntimeFailureMessage == nil
        var batchFailureMessage = batchRuntimeFailureMessage
        if let batchRecording {
            do {
                try await batchRecording.finish()
            } catch {
                batchSucceeded = false
                if batchFailureMessage == nil {
                    batchFailureMessage = error.localizedDescription
                }
            }
        }
        if let batchFailureMessage {
            await batchScheduler?.recordRecordingFailure(
                sessionId: snapshot.sessionId,
                message: batchFailureMessage
            )
        }
        sourceRuntimes.removeAll()
        self.batchRecording = nil
        if snapshot.plan.finalMode == .realtime,
           let recognitionFailure {
            throw recognitionFailure
        }
        return StopResult(
            sessionId: snapshot.sessionId,
            finalMode: snapshot.plan.finalMode,
            batchRecordingSucceeded: batchSucceeded,
            batchFailureMessage: batchFailureMessage
        )
    }

    /// persistence終了後にセッションをidleへ戻す。batch enqueueはユーザー確認後に行う。
    func completeStop() {
        resetState()
    }

    func abort() async {
        await cleanupActiveResources(cancelRecognition: true, deleteBatchRecording: true)
        await cleanupPreparedResources()
        resetState()
    }

    func snapshot() -> Snapshot? {
        switch state {
        case .idle:
            nil
        case let .prepared(snapshot), let .capturing(snapshot), let .stopping(snapshot):
            snapshot
        }
    }

    func resourceCounts() -> ResourceCounts {
        let preparedRecognizerCount = preparation?.sources.count(where: { $0.recognition != nil }) ?? 0
        return ResourceCounts(
            captures: sourceRuntimes.count,
            recognizers: sourceRuntimes.values.count(where: { $0.recognition != nil }) + preparedRecognizerCount,
            batchRecorders: batchRecording == nil ? 0 : sourceRuntimes.count,
            batchSchedulers: batchScheduler == nil ? 0 : 1
        )
    }

    private func cleanupPreparedResources() async {
        if let preparation {
            for preparedSource in preparation.sources {
                await preparedSource.recognition?.session.cancel()
            }
        }
        preparation = nil
        await batchRecording?.cancelPreservingAudio()
        batchRecording = nil
    }

    private func resetState() {
        batchEventTask?.cancel()
        batchEventTask = nil
        preparation = nil
        sourceRuntimes.removeAll()
        sourceRuntimeGenerations.removeAll()
        pendingRecognitionStarts.removeAll()
        batchRecording = nil
        batchScheduler = nil
        onEvent = nil
        onRuntimeFailure = nil
        currentLocale = nil
        batchRuntimeFailureMessage = nil
        state = .idle
    }

    private func startBatchEventMonitoring() {
        guard let batchRecording else { return }
        batchEventTask?.cancel()
        batchEventTask = Task { [weak self, events = batchRecording.events] in
            for await event in events {
                guard !Task.isCancelled else { return }
                await self?.handleBatchRecordingEvent(event)
            }
        }
    }

    private func handleBatchRecordingEvent(_ event: BatchRecordingEvent) async {
        switch event {
        case let .finalizationDelayed(source):
            await onRuntimeFailure?(source, L10n.recordingAudioFinalizationDelayed, false)
        case .finalizationRecovered:
            break
        case let .failed(source, error):
            let durableOffset = await batchRecording?.fullyDurableThroughOffsetSeconds() ?? 0
            let durableDate = snapshot()?.startedAt.addingTimeInterval(durableOffset) ?? .now
            let message = L10n.recordingAudioStoppedWithDurableTime(
                reason: error.localizedDescription,
                durableTime: durableDate.formatted(date: .omitted, time: .standard)
            )
            batchRuntimeFailureMessage = batchRuntimeFailureMessage ?? message
            await onRuntimeFailure?(source, message, true)
        }
    }

    func transition(to newState: State) {
        state = newState
    }

    private static func uniqueSortedConfigurations(
        _ configurations: [SourceConfiguration]
    ) -> [SourceConfiguration] {
        var seen: Set<RecordingAudioSource> = []
        return configurations
            .sorted { $0.source.rawValue < $1.source.rawValue }
            .filter { seen.insert($0.source).inserted }
    }

    static func sortedSources(_ sources: some Sequence<RecordingAudioSource>) -> [RecordingAudioSource] {
        sources.sorted { $0.rawValue < $1.rawValue }
    }

    static func permissionError(for source: RecordingAudioSource) -> Error {
        switch source {
        case .microphone:
            AudioCaptureError.microphonePermissionDenied
        case .system:
            SystemAudioCaptureError.screenRecordingPermissionDenied
        }
    }
}
