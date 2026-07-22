/// macOSの実デバイスcapture sessionを生成するdefault factory。
struct DefaultAudioCaptureSessionFactory: AudioCaptureSessionFactory {
    typealias PermissionRequest = @Sendable () async -> Bool

    private let requestMicrophonePermission: PermissionRequest
    private let requestScreenRecordingPermission: PermissionRequest

    init(
        requestMicrophonePermission: @escaping PermissionRequest = {
            await AudioCaptureManager.requestMicrophonePermission()
        },
        requestScreenRecordingPermission: @escaping PermissionRequest = {
            await SystemAudioCaptureManager.requestPermission()
        }
    ) {
        self.requestMicrophonePermission = requestMicrophonePermission
        self.requestScreenRecordingPermission = requestScreenRecordingPermission
    }

    func requestPermission(for source: RecordingAudioSource) async throws {
        switch source {
        case .microphone:
            guard await requestMicrophonePermission() else {
                throw AudioCaptureError.microphonePermissionDenied
            }
            guard await requestScreenRecordingPermission() else {
                throw SystemAudioCaptureError.screenRecordingPermissionDenied
            }
        case .system:
            guard await requestScreenRecordingPermission() else {
                throw SystemAudioCaptureError.screenRecordingPermissionDenied
            }
        }
    }

    func makeSession(
        for pipeline: AudioSourcePipeline,
        onWarning: @escaping AudioCaptureWarningHandler,
        onUnexpectedStop: @escaping AudioCaptureUnexpectedStopHandler
    ) -> any AudioCaptureSession {
        switch pipeline.source {
        case .microphone:
            MicrophoneAudioCaptureSession(
                pipeline: pipeline,
                onWarning: onWarning,
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
