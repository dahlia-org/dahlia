import CoreAudio

struct MicrophoneDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
    let isBuiltIn: Bool

    init(id: AudioDeviceID, name: String, isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.isBuiltIn = isBuiltIn
    }
}
