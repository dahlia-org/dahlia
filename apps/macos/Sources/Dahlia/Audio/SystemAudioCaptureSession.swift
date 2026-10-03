/// ScreenCaptureKit captureをAudioSourcePipelineへ接続するadapter。
actor SystemAudioCaptureSession: AudioCaptureSession {
    private let manager: SystemAudioCaptureManager
    private let pipeline: AudioSourcePipeline

    init(
        pipeline: AudioSourcePipeline,
        onUnexpectedStop: @escaping AudioCaptureUnexpectedStopHandler
    ) {
        self.pipeline = pipeline
        self.manager = SystemAudioCaptureManager(
            onAudioBuffer: { [pipeline] buffer in
                pipeline.router.route(pipeline.capture(buffer))
            },
            onStreamStopped: { error in
                onUnexpectedStop(error)
            }
        )
    }

    func start() async throws {
        try await manager.startCapture(targetFormat: pipeline.captureFormat)
    }

    func stop() async throws {
        try await manager.stopCaptureAndWait()
    }
}
