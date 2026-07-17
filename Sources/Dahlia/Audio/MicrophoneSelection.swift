import CoreAudio

enum MicrophoneSelection: Hashable {
    case none
    case systemDefault
    case device(AudioDeviceID)

    func resolvedDeviceID(defaultDeviceID: AudioDeviceID?) -> AudioDeviceID? {
        switch self {
        case .none:
            nil
        case .systemDefault:
            defaultDeviceID
        case let .device(deviceID):
            deviceID
        }
    }
}
