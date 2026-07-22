enum MicrophoneRecognitionTestEvent {
    case inputLevel(Double, bufferCount: Int)
    case inputChannelLevels([Double])
    case signalLevels(raw: Double?, processed: Double?)
    case referenceSignal(level: Double, bufferCount: Int)
    case echoCancellationStatistics(WebRTCAEC3Statistics)
    case echoCancellationBypassed
    case transcript(String, isFinal: Bool)
    case failure(String)
    case captureStopped
}
