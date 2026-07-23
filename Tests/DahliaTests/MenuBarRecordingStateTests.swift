#if canImport(Testing)
    import CoreAudio
    import Foundation
    import os
    import Testing
    @testable import Dahlia

    @MainActor
    struct MenuBarRecordingStateTests {
        @Test
        func forwardsMenuSelections() {
            let viewModel = makeViewModel()
            let state = MenuBarRecordingState(viewModel: viewModel)

            state.selectMicrophone(.none)
            state.setSystemAudioEnabled(false)
            state.selectScreenshotSource(.entireDesktop)

            #expect(state.microphoneSelection == .none)
            #expect(viewModel.microphoneSelection == .none)
            #expect(!state.isSystemAudioEnabled)
            #expect(!viewModel.isSystemAudioEnabled)
            #expect(state.screenshotCaptureSource == .entireDesktop)
            #expect(viewModel.screenshotCaptureSource == .entireDesktop)
        }

        @Test
        func reflectsRelevantChangesFromCaptionViewModel() async {
            let microphone = MicrophoneDevice(id: 42, name: "Test Microphone")
            let viewModel = CaptionViewModel(
                availableInputDevicesProvider: { [microphone] },
                defaultInputDeviceIDProvider: { nil }
            )
            let state = MenuBarRecordingState(viewModel: viewModel)
            let window = ScreenshotWindowOption(
                id: 7,
                appName: "Test App",
                title: "Test Window",
                isOnScreen: true
            )

            await state.refreshAvailableMicrophones()
            viewModel.filteredLocales = [Locale(identifier: "en-US")]
            viewModel.availableWindows = [window]

            #expect(state.availableMicrophones == [microphone])
            #expect(state.filteredLocales.map(\.identifier) == ["en-US"])
            #expect(state.availableWindows == [window])
        }

        @Test
        func updatesSystemDefaultMicrophoneTitleFromPublishedValues() async {
            let input = OSAllocatedUnfairLock(
                initialState: MicrophoneInputSnapshot(
                    devices: [MicrophoneDevice(id: 1, name: "First Microphone")],
                    defaultDeviceID: 1
                )
            )
            let viewModel = CaptionViewModel(
                availableInputDevicesProvider: { input.withLock(\.devices) },
                defaultInputDeviceIDProvider: { input.withLock(\.defaultDeviceID) }
            )
            let state = MenuBarRecordingState(viewModel: viewModel)
            await state.refreshAvailableMicrophones()

            input.withLock {
                $0.devices = [MicrophoneDevice(id: 2, name: "Second Microphone")]
                $0.defaultDeviceID = 2
            }
            await state.refreshAvailableMicrophones()

            #expect(state.systemDefaultMicrophoneTitle == L10n.sameAsSystem("Second Microphone"))
        }

        @Test
        func updatesRecordingAvailabilityFromRelevantAudioSelections() {
            let viewModel = makeViewModel()
            let state = MenuBarRecordingState(viewModel: viewModel)

            state.selectMicrophone(.none)
            state.setSystemAudioEnabled(false)
            #expect(!state.canBeginRecording)

            state.setSystemAudioEnabled(true)
            #expect(state.canBeginRecording)
        }

        private func makeViewModel() -> CaptionViewModel {
            CaptionViewModel(
                availableInputDevicesProvider: { [] },
                defaultInputDeviceIDProvider: { nil }
            )
        }
    }

    private struct MicrophoneInputSnapshot {
        var devices: [MicrophoneDevice]
        var defaultDeviceID: AudioDeviceID?
    }
#endif
