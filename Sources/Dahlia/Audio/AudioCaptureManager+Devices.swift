import CoreAudio
import Foundation

extension AudioCaptureManager {
    /// 利用可能なマイク入力デバイス一覧を返す。
    static func availableInputDevices() -> [MicrophoneDevice] {
        inputDeviceIDs()
            .compactMap { deviceID in
                guard let name = deviceName(for: deviceID) else { return nil }
                return MicrophoneDevice(
                    id: deviceID,
                    name: name,
                    isBuiltIn: isBuiltInInputDevice(deviceID)
                )
            }
            .sorted { lhs, rhs in
                lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    static func inputDeviceIDs() -> [AudioDeviceID] {
        var address = globalAddress(kAudioHardwarePropertyDevices)
        var propertySize: UInt32 = 0

        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &propertySize
        ) == noErr else {
            return []
        }

        let count = Int(propertySize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)

        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &propertySize,
            &deviceIDs
        ) == noErr else {
            return []
        }

        return deviceIDs.filter(Self.hasInputStreams)
    }

    /// 現在のデフォルト入力デバイス ID を返す。
    static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = globalAddress(kAudioHardwarePropertyDefaultInputDevice)
        var deviceID = AudioDeviceID(0)
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)

        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &propertySize,
            &deviceID
        ) == noErr,
            deviceID != 0
        else {
            return nil
        }

        return deviceID
    }

    private static func globalAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func hasInputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var propertySize: UInt32 = 0

        return AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &propertySize) == noErr && propertySize > 0
    }

    static func isDeviceRunningSomewhere(_ deviceID: AudioDeviceID) -> Bool {
        var address = globalAddress(kAudioDevicePropertyDeviceIsRunningSomewhere)
        var isRunning: UInt32 = 0
        var propertySize = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &propertySize,
            &isRunning
        ) == noErr else {
            return false
        }
        return isRunning != 0
    }

    static func deviceName(for deviceID: AudioDeviceID) -> String? {
        var address = globalAddress(kAudioObjectPropertyName)
        var propertySize = UInt32(MemoryLayout<CFString?>.size)
        var name: Unmanaged<CFString>?

        guard AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &propertySize,
            &name
        ) == noErr,
            let name
        else {
            return nil
        }

        return name.takeRetainedValue() as String
    }

    static func deviceUID(for deviceID: AudioDeviceID) -> String? {
        var address = globalAddress(kAudioDevicePropertyDeviceUID)
        var propertySize = UInt32(MemoryLayout<CFString?>.size)
        var uid: Unmanaged<CFString>?

        guard AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &propertySize,
            &uid
        ) == noErr,
            let uid
        else {
            return nil
        }

        return uid.takeRetainedValue() as String
    }

    static func isBuiltInInputDevice(_ deviceID: AudioDeviceID) -> Bool {
        var address = globalAddress(kAudioDevicePropertyTransportType)
        var transportType: UInt32 = 0
        var propertySize = UInt32(MemoryLayout<UInt32>.size)

        guard AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &propertySize,
            &transportType
        ) == noErr else {
            return false
        }
        return transportType == kAudioDeviceTransportTypeBuiltIn
    }

    static func inputVolumeState(for deviceID: AudioDeviceID) -> MicrophoneInputVolumeState? {
        var address = inputVolumeAddress()
        guard AudioObjectHasProperty(deviceID, &address) else {
            return nil
        }

        var volume: Float32 = 0
        var propertySize = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &propertySize,
            &volume
        ) == noErr else {
            return nil
        }

        var isSettable = DarwinBoolean(false)
        let canSetVolume = AudioObjectIsPropertySettable(deviceID, &address, &isSettable) == noErr
            && isSettable.boolValue
        return MicrophoneInputVolumeState(value: volume, isSettable: canSetVolume)
    }

    static func setInputVolume(_ volume: Float, for deviceID: AudioDeviceID) -> Bool {
        var address = inputVolumeAddress()
        var isSettable = DarwinBoolean(false)
        guard AudioObjectHasProperty(deviceID, &address),
              AudioObjectIsPropertySettable(deviceID, &address, &isSettable) == noErr,
              isSettable.boolValue else {
            return false
        }

        var clampedVolume = min(max(volume, 0), 1)
        return AudioObjectSetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<Float32>.size),
            &clampedVolume
        ) == noErr
    }

    private static func inputVolumeAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}
