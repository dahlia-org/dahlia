enum MicrophoneRecognitionTestEvent {
    case inputLevel(Double, bufferCount: Int)
    case inputChannelLevels([Double])
    case transcript(String, isFinal: Bool)
    case failure(String)
    case captureStopped
}
