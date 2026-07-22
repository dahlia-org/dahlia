@preconcurrency import AVFoundation
import CoreAudio
import CoreMedia
import os

actor MicrophoneRecognitionTestSession {
    typealias EventHandler = @MainActor @Sendable (MicrophoneRecognitionTestEvent) -> Void

    private static let registry = MicrophoneRecognitionTestRegistry()

    private var screenCaptureManager: ScreenCaptureMicrophoneManager?
    private var bufferPipeline: MicrophoneDiagnosticBufferPipeline?
    private var service: SpeechTranscriberService?
    private var bridge: AudioBufferBridge?
    private var eventHandler: EventHandler?
    private var startGeneration = 0

    static func stopActiveSession() async {
        await registry.stopActiveSession()
    }

    func start(
        deviceID: AudioDeviceID?,
        locale: Locale,
        onEvent: @escaping EventHandler
    ) async throws -> AudioCaptureStartInfo {
        guard screenCaptureManager == nil else {
            throw AudioCaptureError.microphoneDeviceUnavailable
        }
        startGeneration &+= 1
        let generation = startGeneration
        await Self.registry.activate(self)

        do {
            guard await AudioCaptureManager.requestMicrophonePermission() else {
                throw AudioCaptureError.microphonePermissionDenied
            }
            guard await SystemAudioCaptureManager.requestPermission() else {
                throw SystemAudioCaptureError.screenRecordingPermissionDenied
            }
            try ensureCurrentStart(generation)

            let defaultDeviceID = AudioCaptureManager.defaultInputDeviceID()
            let activeDeviceID = MicrophoneEchoCancellationDecision.resolveActiveDeviceID(
                selectedDeviceID: deviceID,
                defaultDeviceID: defaultDeviceID
            )
            guard let activeDeviceID else {
                throw AudioCaptureError.microphoneDeviceUnavailable
            }
            let forcesEchoCancellation = await MainActor.run {
                AppSettings.shared.forceEchoCancellationForExternalMicrophone
            }
            let usesEchoCancellation = MicrophoneEchoCancellationDecision.isEnabled(
                activeDeviceID: activeDeviceID,
                forcesEchoCancellationForExternalMicrophone: forcesEchoCancellation
            )
            let requestedPath: MicrophoneDiagnosticCapturePath = usesEchoCancellation
                ? .screenCaptureEchoCancellation
                : .screenCaptureRaw

            let (service, bridge, targetFormat) = try await prepareRecognition(locale: locale, onEvent: onEvent)
            guard generation == startGeneration else {
                await cancelPreparedRecognition(service: service, bridge: bridge)
                throw CancellationError()
            }

            do {
                let started = try await makeAndStartCapture(
                    path: requestedPath,
                    deviceID: deviceID,
                    defaultDeviceID: defaultDeviceID,
                    activeDeviceID: activeDeviceID,
                    generation: generation,
                    targetFormat: targetFormat,
                    bridge: bridge,
                    onEvent: onEvent
                )
                try ensureCurrentStart(generation)
                attachRecognitionRuntime(service: service, bridge: bridge, onEvent: onEvent)
                return makeStartInfo(
                    started.startInfo,
                    path: requestedPath,
                    targetFormat: targetFormat,
                    pipeline: started.pipeline
                )
            } catch is CancellationError {
                await cancelPreparedRecognition(service: service, bridge: bridge)
                throw CancellationError()
            } catch {
                guard usesEchoCancellation else {
                    await cancelPreparedRecognition(service: service, bridge: bridge)
                    throw error
                }
                await stopCurrentCapture()
                do {
                    let started = try await makeAndStartCapture(
                        path: .screenCaptureRaw,
                        deviceID: deviceID,
                        defaultDeviceID: defaultDeviceID,
                        activeDeviceID: activeDeviceID,
                        generation: generation,
                        targetFormat: targetFormat,
                        bridge: bridge,
                        onEvent: onEvent
                    )
                    try ensureCurrentStart(generation)
                    attachRecognitionRuntime(service: service, bridge: bridge, onEvent: onEvent)
                    await onEvent(.echoCancellationBypassed)
                    return makeStartInfo(
                        started.startInfo,
                        path: .screenCaptureRaw,
                        targetFormat: targetFormat,
                        pipeline: started.pipeline
                    )
                } catch {
                    await cancelPreparedRecognition(service: service, bridge: bridge)
                    throw error
                }
            }
        } catch {
            await stopCurrentCapture()
            await Self.registry.deactivate(self)
            throw error
        }
    }

    func stop() async {
        startGeneration &+= 1
        let bufferPipeline = bufferPipeline
        let bridge = bridge
        let service = service
        let eventHandler = eventHandler
        clearRuntimeReferences()

        await stopCurrentCapture()
        do {
            try bufferPipeline?.finish()
        } catch {
            await eventHandler?(.failure(error.localizedDescription))
        }
        await bufferPipeline?.finishWriting()
        bridge?.finish()
        do {
            try await service?.stopStreaming()
        } catch {
            await eventHandler?(.failure(error.localizedDescription))
        }
        await service?.reset()
        await Self.registry.deactivate(self)
    }

    private func makeAndStartCapture(
        path: MicrophoneDiagnosticCapturePath,
        deviceID: AudioDeviceID?,
        defaultDeviceID: AudioDeviceID?,
        activeDeviceID: AudioDeviceID,
        generation: Int,
        targetFormat: AVAudioFormat,
        bridge: AudioBufferBridge,
        onEvent: @escaping EventHandler
    ) async throws -> (
        pipeline: MicrophoneDiagnosticBufferPipeline,
        startInfo: AudioCaptureStartInfo
    ) {
        let pipeline = try MicrophoneDiagnosticBufferPipeline(
            capturePath: path,
            targetFormat: targetFormat,
            bridge: bridge,
            onEvent: onEvent
        ) { [weak self] error in
            Task {
                await self?.captureStoppedUnexpectedly(error)
            }
        }
        let manager = ScreenCaptureMicrophoneManager()
        manager.onAudioBuffer = { [pipeline] audio in
            pipeline.accept(audio)
        }
        manager.onSystemAudioBuffer = { [pipeline] audio in
            pipeline.acceptSystemAudio(audio)
        }
        manager.onSystemAudioFailure = { [pipeline] error in
            pipeline.handleSystemAudioFailure(error)
        }
        manager.onUnexpectedStop = { [weak self] error in
            Task {
                await self?.captureStoppedUnexpectedly(error)
            }
        }
        pipeline.onEchoCancellationStatistics = { [weak manager] statistics in
            manager?.recordEchoCancellationMetrics(statistics)
        }
        pipeline.onEchoCancellationBypassed = { [weak manager, onEvent] in
            manager?.disableSystemAudioCapture()
            Task { @MainActor in
                onEvent(.echoCancellationBypassed)
            }
        }
        bufferPipeline = pipeline
        screenCaptureManager = manager
        do {
            let startInfo = try await manager.startCapture(
                targetFormat: pipeline.captureFormat,
                selectedDeviceID: deviceID,
                defaultDeviceID: defaultDeviceID,
                activeDeviceID: activeDeviceID,
                path: path
            )
            guard generation == startGeneration, screenCaptureManager === manager else {
                throw CancellationError()
            }
            if path == .screenCaptureEchoCancellation, let latency = pipeline.processingLatency {
                manager.recordEchoCancellationConfiguration(latency: latency, format: pipeline.captureFormat)
            }
            return (pipeline, startInfo)
        } catch {
            await manager.stopCaptureAndWait()
            try? pipeline.finish()
            await pipeline.finishWriting()
            bufferPipeline = nil
            screenCaptureManager = nil
            throw error
        }
    }

    private func makeStartInfo(
        _ startInfo: AudioCaptureStartInfo,
        path: MicrophoneDiagnosticCapturePath,
        targetFormat: AVAudioFormat,
        pipeline: MicrophoneDiagnosticBufferPipeline
    ) -> AudioCaptureStartInfo {
        AudioCaptureStartInfo(
            hardwareFormatDescription: startInfo.hardwareFormatDescription,
            sourceFormatDescription: startInfo.sourceFormatDescription,
            targetFormatDescription: targetFormat.diagnosticDescription,
            capturePath: path,
            processingLatency: pipeline.processingLatency,
            diagnosticOutputDirectory: pipeline.outputDirectory
        )
    }

    private func prepareRecognition(
        locale: Locale,
        onEvent: @escaping EventHandler
    ) async throws -> (SpeechTranscriberService, AudioBufferBridge, AVAudioFormat) {
        let service = SpeechTranscriberService(locale: locale, speakerLabel: RecordingAudioSource.microphone.speakerLabel)
        try await service.prepare()
        guard let targetFormat = await service.targetAudioFormat() else {
            throw AudioCaptureError.converterCreationFailed
        }

        let bridge = try AudioBufferBridge(sourceFormat: targetFormat, analyzerFormat: targetFormat)
        try await service.startStreaming(
            bridge: bridge,
            recordingStartTime: .now,
            recordingSessionId: .v7()
        ) { event in
            await Self.forward(event, to: onEvent)
        }
        return (service, bridge, targetFormat)
    }

    private func attachRecognitionRuntime(
        service: SpeechTranscriberService,
        bridge: AudioBufferBridge,
        onEvent: @escaping EventHandler
    ) {
        self.service = service
        self.bridge = bridge
        eventHandler = onEvent
    }

    private func cancelPreparedRecognition(
        service: SpeechTranscriberService,
        bridge: AudioBufferBridge
    ) async {
        bridge.finish()
        await service.cancel()
    }

    @MainActor
    private static func forward(_ event: TranscriptionEvent, to onEvent: EventHandler) {
        switch event {
        case let .preview(segment):
            onEvent(.transcript(segment.text, isFinal: false))
        case let .finalized(segment):
            onEvent(.transcript(segment.text, isFinal: true))
        case let .failure(_, _, _, message):
            onEvent(.failure(message))
        case .clearPreview, .previewTranslation, .translation:
            break
        }
    }

    private func stopCurrentCapture() async {
        let manager = screenCaptureManager
        screenCaptureManager = nil
        await manager?.stopCaptureAndWait()
    }

    private func captureStoppedUnexpectedly(_ error: Error?) async {
        if let error {
            await eventHandler?(.failure(error.localizedDescription))
        }
        await eventHandler?(.captureStopped)
    }

    private func clearRuntimeReferences() {
        bufferPipeline = nil
        service = nil
        bridge = nil
        eventHandler = nil
    }

    private func ensureCurrentStart(_ generation: Int) throws {
        guard generation == startGeneration else { throw CancellationError() }
    }
}

/// 診断CAFとレベル表示を共通のraw/AEC処理へ接続する。
private final class MicrophoneDiagnosticBufferPipeline: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.dahlia", category: "MicrophoneRecognitionTest")

    let captureFormat: AVAudioFormat
    let processingLatency: TimeInterval?
    let outputDirectory: URL

    var onEchoCancellationStatistics: (@Sendable (WebRTCAEC3Statistics) -> Void)?
    var onEchoCancellationBypassed: (@Sendable () -> Void)?

    private let bridge: AudioBufferBridge
    private let writer: MicrophoneDiagnosticAudioWriter
    private let processor: MicrophoneCaptureBufferProcessor
    private let onEvent: MicrophoneRecognitionTestSession.EventHandler
    private let frameOffset = OSAllocatedUnfairLock(initialState: Int64(0))
    private let bufferCount = OSAllocatedUnfairLock(initialState: 0)
    private let timescale: CMTimeScale
    private var referenceBufferCount = 0

    init(
        capturePath: MicrophoneDiagnosticCapturePath,
        targetFormat: AVAudioFormat,
        bridge: AudioBufferBridge,
        onEvent: @escaping MicrophoneRecognitionTestSession.EventHandler,
        onFailure: @escaping @Sendable (Error) -> Void
    ) throws {
        let usesEchoCancellation = capturePath == .screenCaptureEchoCancellation
        let processor = try MicrophoneCaptureBufferProcessor(
            targetFormat: targetFormat,
            usesEchoCancellation: usesEchoCancellation
        )
        let writer = try MicrophoneDiagnosticAudioWriter(
            rawFormat: processor.captureFormat,
            processedFormat: usesEchoCancellation ? processor.captureFormat : nil,
            referenceFormat: usesEchoCancellation ? processor.captureFormat : nil
        )
        self.bridge = bridge
        self.writer = writer
        self.processor = processor
        self.onEvent = onEvent
        captureFormat = processor.captureFormat
        processingLatency = processor.processingLatency
        outputDirectory = writer.directoryURL
        timescale = CMTimeScale(targetFormat.sampleRate.rounded())

        writer.onFailure = onFailure
        processor.onRawBuffer = { [writer, onEvent] buffer in
            writer.appendRaw(buffer)
            let level = AudioLevelCalculator.normalizedLevel(in: buffer)
            Task { @MainActor in
                onEvent(.signalLevels(raw: level, processed: nil))
            }
        }
        processor.onProcessedBuffer = { [writer, onEvent] buffer in
            writer.appendProcessed(buffer)
            let level = AudioLevelCalculator.normalizedLevel(in: buffer)
            Task { @MainActor in
                onEvent(.signalLevels(raw: nil, processed: level))
            }
        }
        processor.onReferenceBuffer = { [weak self, writer, onEvent] buffer in
            writer.appendReference(buffer)
            guard let self else { return }
            referenceBufferCount += 1
            let count = referenceBufferCount
            let level = AudioLevelCalculator.normalizedLevel(in: buffer)
            Task { @MainActor in
                onEvent(.referenceSignal(level: level, bufferCount: count))
            }
        }
        processor.onOutputBuffer = { [weak self] buffer in
            self?.deliver(buffer)
        }
        processor.onEchoCancellationBypassed = { [weak self] _ in
            self?.onEchoCancellationBypassed?()
        }
        processor.onEchoCancellationStatistics = { [weak self, onEvent] statistics in
            self?.onEchoCancellationStatistics?(statistics)
            Task { @MainActor in
                onEvent(.echoCancellationStatistics(statistics))
            }
        }
        processor.onFailure = onFailure
    }

    func accept(_ audio: ScreenCaptureAudioBuffer) {
        processor.acceptMicrophone(audio)
    }

    func acceptSystemAudio(_ audio: ScreenCaptureAudioBuffer) {
        processor.acceptSystemAudio(audio)
    }

    func handleSystemAudioFailure(_ error: Error) {
        processor.handleSystemAudioFailure(error)
    }

    func finish() throws {
        try processor.finish()
    }

    func finishWriting() async {
        await writer.finish()
    }

    private func deliver(_ buffer: AVAudioPCMBuffer) {
        let frameLength = Int64(buffer.frameLength)
        let startFrame = frameOffset.withLock { offset in
            let startFrame = offset
            offset += frameLength
            return startFrame
        }
        let count = bufferCount.withLock { count in
            count += 1
            return count
        }
        let chunk = CapturedAudioChunk(
            source: .microphone,
            buffer: buffer,
            sessionRelativeStartTime: CMTime(value: startFrame, timescale: timescale)
        )
        if !bridge.append(chunk) {
            Self.logger.error("Speech analyzer rejected microphone buffer \(count)")
        }
        let level = AudioLevelCalculator.normalizedLevel(in: buffer)
        let channelLevels = AudioLevelCalculator.normalizedLevels(in: buffer)
        Task { @MainActor [onEvent] in
            onEvent(.inputLevel(level, bufferCount: count))
            onEvent(.inputChannelLevels(channelLevels))
        }
    }
}

private actor MicrophoneRecognitionTestRegistry {
    private var activeSession: MicrophoneRecognitionTestSession?

    func activate(_ session: MicrophoneRecognitionTestSession) async {
        guard activeSession !== session else { return }
        let previousSession = activeSession
        activeSession = session
        await previousSession?.stop()
    }

    func deactivate(_ session: MicrophoneRecognitionTestSession) {
        if activeSession === session {
            activeSession = nil
        }
    }

    func stopActiveSession() async {
        let session = activeSession
        activeSession = nil
        await session?.stop()
    }
}
