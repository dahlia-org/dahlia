import CoreAudio

struct MicrophoneDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
}
