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
    private let listenerQueue = DispatchQueue(label: "com.dahlia.audioHardwareListeners")
    private var monitoringOwnerID: UUID?
    private var deviceListeners: [(id: AudioDeviceID, block: AudioObjectPropertyListenerBlock)] = []
    private var deviceListChangeBlock: AudioObjectPropertyListenerBlock?

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

    func defaultInputDeviceID() -> AudioDeviceID? {
        guard !Task.isCancelled else { return nil }
        return defaultInputDeviceIDProvider()
    }

    func inputDeviceIDs() -> [AudioDeviceID] {
        guard !Task.isCancelled else { return [] }
        return inputDeviceIDsProvider()
    }

    func isAnyInputDeviceRunning(in deviceIDs: [AudioDeviceID]) -> Bool {
        guard !Task.isCancelled else { return false }
        return deviceIDs.contains(where: isDeviceRunningProvider)
    }

    func startMonitoring(
        ownerID: UUID,
        onDeviceListChange: @escaping @Sendable () -> Void
    ) {
        removeAllListeners()
        monitoringOwnerID = ownerID

        var address = Self.globalAddress(kAudioHardwarePropertyDevices)
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            onDeviceListChange()
        }
        deviceListChangeBlock = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            listenerQueue,
            block
        )
    }

    func replaceRunningStateListeners(
        ownerID: UUID,
        deviceIDs: [AudioDeviceID],
        onRunningStateChange: @escaping @Sendable () -> Void
    ) {
        guard monitoringOwnerID == ownerID else { return }
        removeRunningStateListeners()

        for deviceID in deviceIDs {
            var address = Self.globalAddress(kAudioDevicePropertyDeviceIsRunningSomewhere)
            let block: AudioObjectPropertyListenerBlock = { _, _ in
                onRunningStateChange()
            }
            AudioObjectAddPropertyListenerBlock(deviceID, &address, listenerQueue, block)
            deviceListeners.append((id: deviceID, block: block))
        }
    }

    func stopMonitoring(ownerID: UUID) {
        guard monitoringOwnerID == ownerID else { return }
        removeAllListeners()
        monitoringOwnerID = nil
    }

    private func removeAllListeners() {
        removeRunningStateListeners()
        guard let block = deviceListChangeBlock else { return }
        var address = Self.globalAddress(kAudioHardwarePropertyDevices)
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            listenerQueue,
            block
        )
        deviceListChangeBlock = nil
    }

    private func removeRunningStateListeners() {
        for listener in deviceListeners {
            var address = Self.globalAddress(kAudioDevicePropertyDeviceIsRunningSomewhere)
            AudioObjectRemovePropertyListenerBlock(listener.id, &address, listenerQueue, listener.block)
        }
        deviceListeners.removeAll()
    }

    private static func globalAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}
