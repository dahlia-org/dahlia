import CoreAudio
import Foundation

/// ScreenCaptureKit microphone captureをAudioSourcePipelineへ接続するadapter。
actor MicrophoneAudioCaptureSession: AudioCaptureSession {
    private let pipeline: AudioSourcePipeline
    private let onWarning: AudioCaptureWarningHandler
    private let onUnexpectedStop: AudioCaptureUnexpectedStopHandler
    private var manager: ScreenCaptureMicrophoneManager?
    private var bufferProcessor: MicrophoneCaptureBufferProcessor?
    private var isStopping = false
    private var isStarting = false
    private var startGeneration = 0

    init(
        pipeline: AudioSourcePipeline,
        onWarning: @escaping AudioCaptureWarningHandler,
        onUnexpectedStop: @escaping AudioCaptureUnexpectedStopHandler
    ) {
        self.pipeline = pipeline
        self.onWarning = onWarning
        self.onUnexpectedStop = onUnexpectedStop
    }

    func start() async throws {
        guard !isStarting, manager == nil else {
            throw AudioCaptureError.microphoneDeviceUnavailable
        }
        isStarting = true
        startGeneration &+= 1
        let generation = startGeneration
        defer { isStarting = false }
        isStopping = false
        await MicrophoneRecognitionTestSession.stopActiveSession()
        try ensureCurrentStart(generation)

        let defaultDeviceID = AudioCaptureManager.defaultInputDeviceID()
        let activeDeviceID = MicrophoneEchoCancellationDecision.resolveActiveDeviceID(
            selectedDeviceID: pipeline.captureDeviceID,
            defaultDeviceID: defaultDeviceID
        )
        guard let activeDeviceID else {
            throw AudioCaptureError.microphoneDeviceUnavailable
        }
        let usesEchoCancellation = MicrophoneEchoCancellationDecision.isEnabled(
            activeDeviceID: activeDeviceID,
            forcesEchoCancellationForExternalMicrophone: pipeline.forcesEchoCancellationForExternalMicrophone
        )

        do {
            try await startCapture(
                usesEchoCancellation: usesEchoCancellation,
                defaultDeviceID: defaultDeviceID,
                activeDeviceID: activeDeviceID,
                generation: generation
            )
        } catch {
            await stopCurrentCapture()
            try ensureCurrentStart(generation)
            guard usesEchoCancellation, !(error is CancellationError) else { throw error }
            do {
                try await startCapture(
                    usesEchoCancellation: false,
                    defaultDeviceID: defaultDeviceID,
                    activeDeviceID: activeDeviceID,
                    generation: generation
                )
            } catch {
                await stopCurrentCapture()
                throw error
            }
            onWarning(AudioCaptureError.echoCancellationBypassed)
        }
    }

    func stop() async throws {
        startGeneration &+= 1
        isStopping = true
        let processor = bufferProcessor
        await stopCurrentCapture()
        try processor?.finish()
    }

    private func startCapture(
        usesEchoCancellation: Bool,
        defaultDeviceID: AudioDeviceID?,
        activeDeviceID: AudioDeviceID,
        generation: Int
    ) async throws {
        let processor = try MicrophoneCaptureBufferProcessor(
            targetFormat: pipeline.captureFormat,
            usesEchoCancellation: usesEchoCancellation
        )
        let manager = ScreenCaptureMicrophoneManager()
        processor.onOutputBuffer = { [pipeline] buffer in
            pipeline.router.route(pipeline.capture(buffer))
        }
        processor.onEchoCancellationBypassed = { [weak manager, onWarning] _ in
            manager?.disableSystemAudioCapture()
            onWarning(AudioCaptureError.echoCancellationBypassed)
        }
        processor.onFailure = { [weak self] error in
            Task {
                await self?.captureStoppedUnexpectedly(error)
            }
        }
        processor.onEchoCancellationStatistics = { [weak manager] statistics in
            manager?.recordEchoCancellationMetrics(statistics)
        }
        manager.onAudioBuffer = { [processor] audio in
            processor.acceptMicrophone(audio)
        }
        manager.onSystemAudioBuffer = { [processor] audio in
            processor.acceptSystemAudio(audio)
        }
        manager.onSystemAudioFailure = { [processor] error in
            processor.handleSystemAudioFailure(error)
        }
        manager.onUnexpectedStop = { [weak self] error in
            Task {
                await self?.captureStoppedUnexpectedly(error)
            }
        }
        bufferProcessor = processor
        self.manager = manager

        let path: MicrophoneDiagnosticCapturePath = usesEchoCancellation
            ? .screenCaptureEchoCancellation
            : .screenCaptureRaw
        _ = try await manager.startCapture(
            targetFormat: processor.captureFormat,
            selectedDeviceID: pipeline.captureDeviceID,
            defaultDeviceID: defaultDeviceID,
            activeDeviceID: activeDeviceID,
            path: path,
            context: .recording
        )
        guard generation == startGeneration, self.manager === manager else {
            await manager.stopCaptureAndWait()
            throw CancellationError()
        }
        if usesEchoCancellation, let processingLatency = processor.processingLatency {
            manager.recordEchoCancellationConfiguration(
                latency: processingLatency,
                format: processor.captureFormat
            )
        }
    }

    private func stopCurrentCapture() async {
        let manager = manager
        self.manager = nil
        bufferProcessor = nil
        await manager?.stopCaptureAndWait()
    }

    private func captureStoppedUnexpectedly(_ error: Error?) {
        guard !isStopping else { return }
        onUnexpectedStop(error)
    }

    private func ensureCurrentStart(_ generation: Int) throws {
        guard generation == startGeneration else { throw CancellationError() }
    }
}
