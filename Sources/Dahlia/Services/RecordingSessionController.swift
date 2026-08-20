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
    typealias AudioLevelHandler = @MainActor @Sendable (
        _ source: RecordingAudioSource,
        _ level: Double
    ) -> Void

    struct SourceConfiguration: Equatable {
        let source: RecordingAudioSource
        let captureDeviceID: AudioDeviceID?
        let forcesEchoCancellationForExternalMicrophone: Bool

        init(
            source: RecordingAudioSource,
            captureDeviceID: AudioDeviceID? = nil,
            forcesEchoCancellationForExternalMicrophone: Bool = false
        ) {
            self.source = source
            self.captureDeviceID = captureDeviceID
            self.forcesEchoCancellationForExternalMicrophone = forcesEchoCancellationForExternalMicrophone
        }
    }

    struct PreparationRequest {
        let sessionId: UUID
        let startedAt: Date
        let plan: TranscriptionSessionPlan
        let transcriptionLocale: Locale
        let liveRecognitionLocale: Locale
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
            liveRecognitionLocale: Locale? = nil,
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
            transcriptionLocale = locale
            self.liveRecognitionLocale = liveRecognitionLocale ?? locale
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
        let captureFailureMessage: String?
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
        var transcriptionLocaleIdentifier: String
        var liveRecognitionLocaleIdentifier: String
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
        let transcriptionLocale: Locale
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
    var audioLevelDeliveryGates: [RecordingAudioSource: RecordingAudioLevelDeliveryGate] = [:]
    var pendingRecognitionStarts: [UUID: PendingRecognitionStart] = [:]
    var batchRecording: (any BatchRecordingSession)?
    var batchEventTask: Task<Void, Never>?
    private var batchScheduler: (any BatchTranscriptionScheduling)?
    var onEvent: EventHandler?
    var onRuntimeFailure: RuntimeFailureHandler?
    var onAudioLevel: AudioLevelHandler?
    var currentTranscriptionLocale: Locale?
    var currentLiveRecognitionLocale: Locale?
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
        onRuntimeFailure: @escaping RuntimeFailureHandler,
        onAudioLevel: @escaping AudioLevelHandler = { _, _ in }
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
                try await captureFactory.requestPermission(for: configuration.source)
            }

            var recognitionModelIsAvailable = request.plan.requiresLiveRecognition
            if request.plan.requiresLiveRecognition {
                do {
                    try await recognitionFactory.prepareModel(locale: request.liveRecognitionLocale)
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
                            locale: request.liveRecognitionLocale,
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
                transcriptionLocaleIdentifier: request.transcriptionLocale.identifier,
                liveRecognitionLocaleIdentifier: request.liveRecognitionLocale.identifier,
                enabledSources: Set(configurations.map(\.source))
            )
            preparation = Preparation(
                sources: preparedSources,
                transcriptionLocale: request.transcriptionLocale
            )
            batchScheduler = request.batchScheduler
            self.onEvent = onEvent
            self.onRuntimeFailure = onRuntimeFailure
            self.onAudioLevel = onAudioLevel
            currentTranscriptionLocale = request.transcriptionLocale
            currentLiveRecognitionLocale = request.liveRecognitionLocale
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
                    locale: preparation.transcriptionLocale,
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
        invalidateAllAudioLevelDeliveries()

        let firstCaptureFailure = await stopCaptures()
        await drainRouters()
        let recognitionFailure = await finishRecognitions(
            isFatal: snapshot.plan.finalMode == .realtime
        )
        let captureFailureMessage = firstCaptureFailure?.localizedDescription
        let batchResult = await finishBatchRecording(
            sessionId: snapshot.sessionId,
            captureFailureMessage: captureFailureMessage
        )
        if snapshot.plan.finalMode == .realtime {
            if let firstCaptureFailure {
                throw firstCaptureFailure
            }
            if let recognitionFailure {
                throw recognitionFailure
            }
        }
        sourceRuntimes.removeAll()
        batchRecording = nil
        return StopResult(
            sessionId: snapshot.sessionId,
            finalMode: snapshot.plan.finalMode,
            batchRecordingSucceeded: batchResult.succeeded,
            batchFailureMessage: batchResult.failureMessage,
            captureFailureMessage: captureFailureMessage
        )
    }

    private func drainRouters() async {
        for runtime in sourceRuntimes.values {
            runtime.pipeline.router.removeAllConsumers()
        }
        for runtime in sourceRuntimes.values {
            await runtime.pipeline.router.waitUntilIdle()
        }
    }

    private func finishRecognitions(isFatal: Bool) async -> Error? {
        var firstFailure: Error?
        for source in Self.sortedSources(sourceRuntimes.keys) {
            guard let recognition = sourceRuntimes[source]?.recognition else { continue }
            do {
                try await recognition.finish()
            } catch {
                firstFailure = firstFailure ?? error
                await onRuntimeFailure?(
                    source,
                    error.localizedDescription,
                    isFatal
                )
            }
        }
        return firstFailure
    }

    private func finishBatchRecording(
        sessionId: UUID,
        captureFailureMessage: String?
    ) async -> (succeeded: Bool, failureMessage: String?) {
        var succeeded = batchRuntimeFailureMessage == nil
        var failureMessage = batchRuntimeFailureMessage
        if let batchRecording {
            do {
                try await batchRecording.finish()
            } catch {
                succeeded = false
                failureMessage = failureMessage ?? error.localizedDescription
            }
        }
        if let recordingFailureMessage = failureMessage ?? captureFailureMessage {
            await batchScheduler?.recordRecordingFailure(
                sessionId: sessionId,
                message: recordingFailureMessage
            )
        }
        return (succeeded, failureMessage)
    }

    private func stopCaptures() async -> Error? {
        var firstFailure: Error?
        for source in Self.sortedSources(sourceRuntimes.keys) {
            do {
                try await sourceRuntimes[source]?.capture.stop()
            } catch {
                firstFailure = firstFailure ?? error
            }
        }
        return firstFailure
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
        invalidateAllAudioLevelDeliveries()
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
        onAudioLevel = nil
        currentTranscriptionLocale = nil
        currentLiveRecognitionLocale = nil
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
}
