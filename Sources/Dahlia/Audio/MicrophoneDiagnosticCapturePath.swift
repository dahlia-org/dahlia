enum MicrophoneDiagnosticCapturePath: String, CaseIterable, Identifiable, Sendable {
    case screenCaptureRaw
    case screenCaptureEchoCancellation

    var id: Self { self }
}
