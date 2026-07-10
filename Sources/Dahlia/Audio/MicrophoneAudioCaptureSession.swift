/// AVAudioEngine captureをAudioSourcePipelineへ接続するadapter。
actor MicrophoneAudioCaptureSession: AudioCaptureSession {
    private let manager: AudioCaptureManager
    private let pipeline: AudioSourcePipeline

    init(pipeline: AudioSourcePipeline) {
        self.pipeline = pipeline
        let manager = AudioCaptureManager()
        manager.onAudioBuffer = { [pipeline] buffer in
            pipeline.router.route(pipeline.capture(buffer))
        }
        self.manager = manager
    }

    func start() throws {
        try manager.startCapture(
            targetFormat: pipeline.captureFormat,
            selectedDeviceID: pipeline.captureDeviceID,
            bufferSize: pipeline.captureBufferSize
        )
    }

    func stop() {
        manager.stopCapture()
    }
}
