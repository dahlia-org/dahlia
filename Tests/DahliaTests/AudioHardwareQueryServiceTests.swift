#if canImport(Testing)
    import CoreAudio
    import os
    import Testing
    @testable import Dahlia

    struct AudioHardwareQueryServiceTests {
        @Test
        func inputVolumeOperationsUseTheRequestedDevice() async {
            let state = OSAllocatedUnfairLock(initialState: (deviceID: AudioDeviceID(0), volume: Float(0)))
            let service = AudioHardwareQueryService(
                availableInputDevicesProvider: { [] },
                defaultInputDeviceIDProvider: { nil },
                inputVolumeStateProvider: { deviceID in
                    switch deviceID {
                    case 42:
                        MicrophoneInputVolumeState(value: 0.75, isSettable: true)
                    case 7:
                        MicrophoneInputVolumeState(value: 0.25, isSettable: false)
                    default:
                        nil
                    }
                },
                inputVolumeSetter: { volume, deviceID in
                    guard deviceID == 42 else { return false }
                    state.withLock {
                        $0 = (deviceID, volume)
                    }
                    return true
                }
            )

            #expect(await service.inputVolumeState(for: 42) ==
                MicrophoneInputVolumeState(value: 0.75, isSettable: true))
            #expect(await service.inputVolumeState(for: 7) ==
                MicrophoneInputVolumeState(value: 0.25, isSettable: false))
            #expect(await service.inputVolumeState(for: 99) == nil)
            #expect(await service.setInputVolume(0.9, for: 42))
            #expect(await !(service.setInputVolume(0.5, for: 7)))
            #expect(state.withLock { $0.deviceID } == 42)
            #expect(state.withLock { $0.volume } == 0.9)
        }
    }
#endif
