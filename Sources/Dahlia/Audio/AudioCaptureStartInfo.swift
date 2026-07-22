import Foundation

struct AudioCaptureStartInfo: Equatable {
    let hardwareFormatDescription: String
    let sourceFormatDescription: String
    let targetFormatDescription: String
    let capturePath: MicrophoneDiagnosticCapturePath?
    let processingLatency: TimeInterval?
    let diagnosticOutputDirectory: URL?

    init(
        hardwareFormatDescription: String,
        sourceFormatDescription: String,
        targetFormatDescription: String,
        capturePath: MicrophoneDiagnosticCapturePath? = nil,
        processingLatency: TimeInterval? = nil,
        diagnosticOutputDirectory: URL? = nil
    ) {
        self.hardwareFormatDescription = hardwareFormatDescription
        self.sourceFormatDescription = sourceFormatDescription
        self.targetFormatDescription = targetFormatDescription
        self.capturePath = capturePath
        self.processingLatency = processingLatency
        self.diagnosticOutputDirectory = diagnosticOutputDirectory
    }
}
