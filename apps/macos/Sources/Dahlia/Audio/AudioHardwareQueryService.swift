import CoreAudio

struct MicrophoneInputVolumeState: Equatable, Sendable {
    let value: Float
    let isSettable: Bool
}

struct MicrophoneDeviceSnapshot {
    let devices: [MicrophoneDevice]
    let defaultDeviceID: AudioDeviceID?
}

/// CoreAudio HAL の同期問い合わせを MainActor から隔離し、同時問い合わせを直列化する。
///
/// HAL はデバイス変更時などに XPC 応答や内部 mutex を長時間待つことがあるため、
/// UI や録音制御を担当する MainActor から直接呼び出さない。
actor AudioHardwareQueryService {
    static let shared = AudioHardwareQueryService()

    private let availableInputDevicesProvider: @Sendable () -> [MicrophoneDevice]
    private let defaultInputDeviceIDProvider: @Sendable () -> AudioDeviceID?
    private let inputVolumeStateProvider: @Sendable (AudioDeviceID) -> MicrophoneInputVolumeState?
    private let inputVolumeSetter: @Sendable (Float, AudioDeviceID) -> Bool

    init(
        availableInputDevicesProvider: @escaping @Sendable () -> [MicrophoneDevice] = AudioCaptureManager.availableInputDevices,
        defaultInputDeviceIDProvider: @escaping @Sendable () -> AudioDeviceID? = AudioCaptureManager.defaultInputDeviceID,
        inputVolumeStateProvider: @escaping @Sendable (AudioDeviceID) -> MicrophoneInputVolumeState? = AudioCaptureManager.inputVolumeState,
        inputVolumeSetter: @escaping @Sendable (Float, AudioDeviceID) -> Bool = AudioCaptureManager.setInputVolume
    ) {
        self.availableInputDevicesProvider = availableInputDevicesProvider
        self.defaultInputDeviceIDProvider = defaultInputDeviceIDProvider
        self.inputVolumeStateProvider = inputVolumeStateProvider
        self.inputVolumeSetter = inputVolumeSetter
    }

    func microphoneSnapshot() -> MicrophoneDeviceSnapshot {
        guard !Task.isCancelled else {
            return MicrophoneDeviceSnapshot(devices: [], defaultDeviceID: nil)
        }
        return MicrophoneDeviceSnapshot(
            devices: availableInputDevicesProvider(),
            defaultDeviceID: defaultInputDeviceIDProvider()
        )
    }

    func defaultInputDeviceID() -> AudioDeviceID? {
        guard !Task.isCancelled else { return nil }
        return defaultInputDeviceIDProvider()
    }

    func inputVolumeState(for deviceID: AudioDeviceID) -> MicrophoneInputVolumeState? {
        guard !Task.isCancelled else { return nil }
        return inputVolumeStateProvider(deviceID)
    }

    func setInputVolume(_ volume: Float, for deviceID: AudioDeviceID) -> Bool {
        guard !Task.isCancelled else { return false }
        return inputVolumeSetter(volume, deviceID)
    }
}
