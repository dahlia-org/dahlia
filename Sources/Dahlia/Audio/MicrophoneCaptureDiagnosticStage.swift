enum MicrophoneCaptureDiagnosticStage: String {
    case captureRequested = "Capture Requested"
    case screenCaptureKitConfigured = "ScreenCaptureKit Configured"
    case echoCancellationConfigured = "Echo Cancellation Configured"
    case echoCancellationMetrics = "Echo Cancellation Metrics"
    case firstAudioBufferReceived = "First Audio Buffer Received"
    case firstSystemAudioBufferReceived = "First System Audio Buffer Received"
    case captureStopped = "Capture Stopped"
    case unexpectedStop = "Unexpected Capture Stop"
    case attemptFailed = "Capture Attempt Failed"
}
