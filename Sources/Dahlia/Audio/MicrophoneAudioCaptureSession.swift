/// AVAudioEngine captureをAudioSourcePipelineへ接続するadapter。
actor MicrophoneAudioCaptureSession: AudioCaptureSession {
    private let manager: AudioCaptureManager
    private let pipeline: AudioSourcePipeline
    private let onUnexpectedStop: AudioCaptureUnexpectedStopHandler
    private var isStopping = false

    init(
        pipeline: AudioSourcePipeline,
        onInterruption: @escaping AudioCaptureInterruptionHandler,
        onUnexpectedStop: @escaping AudioCaptureUnexpectedStopHandler
    ) {
        self.pipeline = pipeline
        self.onUnexpectedStop = onUnexpectedStop
        let manager = AudioCaptureManager()
        manager.onAudioBuffer = { [pipeline] buffer in
            pipeline.router.route(pipeline.capture(buffer))
        }
        self.manager = manager
        manager.onInterruption = onInterruption
        manager.onUnexpectedStop = { [weak self] error in
            Task {
                await self?.captureStoppedUnexpectedly(error)
            }
        }
    }

    func start() async throws {
        isStopping = false
        await MicrophoneRecognitionTestSession.stopActiveSession()
        try manager.startCapture(
            targetFormat: pipeline.captureFormat,
            selectedDeviceID: pipeline.captureDeviceID,
            bufferSize: pipeline.captureBufferSize
        )
    }

    func stop() {
        isStopping = true
        manager.stopCapture()
    }

    private func captureStoppedUnexpectedly(_ error: AudioCaptureError?) {
        guard !isStopping else { return }
        onUnexpectedStop(error)
    }
}
