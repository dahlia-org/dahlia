/// ScreenCaptureKit captureをAudioSourcePipelineへ接続するadapter。
actor SystemAudioCaptureSession: AudioCaptureSession {
    private let manager: SystemAudioCaptureManager
    private let pipeline: AudioSourcePipeline
    private let onUnexpectedStop: AudioCaptureUnexpectedStopHandler
    private var isStopping = false

    init(
        pipeline: AudioSourcePipeline,
        onUnexpectedStop: @escaping AudioCaptureUnexpectedStopHandler
    ) {
        self.pipeline = pipeline
        self.onUnexpectedStop = onUnexpectedStop
        let manager = SystemAudioCaptureManager()
        manager.onAudioBuffer = { [pipeline] buffer in
            pipeline.router.route(pipeline.capture(buffer))
        }
        self.manager = manager
        manager.onStreamStopped = { [weak self] error in
            Task {
                await self?.streamDidStop(error: error)
            }
        }
    }

    func start() async throws {
        isStopping = false
        try await manager.startCapture(targetFormat: pipeline.captureFormat)
    }

    func stop() async throws {
        isStopping = true
        try await manager.stopCaptureAndWait()
    }

    private func streamDidStop(error: Error?) {
        guard !isStopping else { return }
        onUnexpectedStop(error)
    }
}
