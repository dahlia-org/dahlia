import CoreAudio
import Foundation

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
    private let inputDeviceIDsProvider: @Sendable () -> [AudioDeviceID]
    private let isDeviceRunningProvider: @Sendable (AudioDeviceID) -> Bool

    init(
        availableInputDevicesProvider: @escaping @Sendable () -> [MicrophoneDevice] = AudioCaptureManager.availableInputDevices,
        defaultInputDeviceIDProvider: @escaping @Sendable () -> AudioDeviceID? = AudioCaptureManager.defaultInputDeviceID,
        inputDeviceIDsProvider: @escaping @Sendable () -> [AudioDeviceID] = AudioCaptureManager.inputDeviceIDs,
        isDeviceRunningProvider: @escaping @Sendable (AudioDeviceID) -> Bool = AudioCaptureManager.isDeviceRunningSomewhere
    ) {
        self.availableInputDevicesProvider = availableInputDevicesProvider
        self.defaultInputDeviceIDProvider = defaultInputDeviceIDProvider
        self.inputDeviceIDsProvider = inputDeviceIDsProvider
        self.isDeviceRunningProvider = isDeviceRunningProvider
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

    func inputDeviceIDs() -> [AudioDeviceID] {
        guard !Task.isCancelled else { return [] }
        return inputDeviceIDsProvider()
    }

    func isAnyInputDeviceRunning(in deviceIDs: [AudioDeviceID]) -> Bool {
        guard !Task.isCancelled else { return false }
        return deviceIDs.contains(where: isDeviceRunningProvider)
    }
}
