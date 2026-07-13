/// macOSの実デバイスcapture sessionを生成するdefault factory。
struct DefaultAudioCaptureSessionFactory: AudioCaptureSessionFactory {
    func requestPermission(for source: RecordingAudioSource) async -> Bool {
        switch source {
        case .microphone:
            await AudioCaptureManager.requestMicrophonePermission()
        case .system:
            await SystemAudioCaptureManager.requestPermission()
        }
    }

    func makeSession(
        for pipeline: AudioSourcePipeline,
        onInterruption: @escaping AudioCaptureInterruptionHandler,
        onUnexpectedStop: @escaping AudioCaptureUnexpectedStopHandler
    ) -> any AudioCaptureSession {
        switch pipeline.source {
        case .microphone:
            MicrophoneAudioCaptureSession(
                pipeline: pipeline,
                onInterruption: onInterruption,
                onUnexpectedStop: onUnexpectedStop
            )
        case .system:
            SystemAudioCaptureSession(
                pipeline: pipeline,
                onUnexpectedStop: onUnexpectedStop
            )
        }
    }
}
