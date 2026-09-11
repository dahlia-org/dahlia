enum SummaryGenerationSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case transcript
    case audio

    var id: Self { self }

    var processingMethod: RecordingProcessingMethod {
        switch self {
        case .transcript: .transcript
        case .audio: .audio
        }
    }
}
