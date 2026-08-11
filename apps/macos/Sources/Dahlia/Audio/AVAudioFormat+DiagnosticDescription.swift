@preconcurrency import AVFoundation

extension AVAudioFormat {
    var diagnosticDescription: String {
        "\(Int(sampleRate.rounded())) Hz, \(channelCount) ch, \(diagnosticCommonFormatName)"
    }

    private var diagnosticCommonFormatName: String {
        switch commonFormat {
        case .pcmFormatFloat32: "Float32"
        case .pcmFormatFloat64: "Float64"
        case .pcmFormatInt16: "Int16"
        case .pcmFormatInt32: "Int32"
        case .otherFormat: "Other"
        @unknown default: "Unknown"
        }
    }
}
