import SwiftUI

struct MenuBarRecordingControls: View {
    let state: MenuBarRecordingState
    let recordingCoordinator: RecordingCoordinator

    @AppStorage("liveSubtitleOverlayEnabled") private var liveSubtitleOverlayEnabled = false

    var body: some View {
        VStack {
            Button(action: toggleRecording) {
                Label(
                    state.isListening ? L10n.menuBarStopRecording : L10n.menuBarStartRecording,
                    systemImage: state.isListening ? "stop.fill" : "record.circle"
                )
            }
            .disabled(
                !state.isListening
                    && (!state.canBeginRecording || !recordingCoordinator.canStartNewMeeting)
                    && AppSettings.shared.currentVault != nil
            )

            Toggle(isOn: $liveSubtitleOverlayEnabled) {
                Label(L10n.menuBarShowLiveSubtitles, systemImage: "text.bubble")
            }
            recordingSettingsMenus
        }
        .onAppear {
            state.refreshAvailableWindows()
        }
        .task {
            await state.refreshAvailableMicrophones()
        }
    }

    @ViewBuilder
    private var recordingSettingsMenus: some View {
        Menu {
            Button {
                state.selectMicrophone(.none)
            } label: {
                selectionLabel(L10n.none, isSelected: state.microphoneSelection == .none)
            }
            Divider()
            Button {
                state.selectMicrophone(.systemDefault)
            } label: {
                selectionLabel(
                    state.systemDefaultMicrophoneTitle,
                    isSelected: state.microphoneSelection == .systemDefault
                )
            }

            if !state.availableMicrophones.isEmpty {
                Divider()
            }

            ForEach(state.availableMicrophones) { microphone in
                Button {
                    state.selectMicrophone(.device(microphone.id))
                } label: {
                    selectionLabel(
                        microphone.name,
                        isSelected: state.microphoneSelection == .device(microphone.id)
                    )
                }
            }
        } label: {
            Label(L10n.microphone, systemImage: "mic.fill")
        }

        Menu {
            Button {
                state.setSystemAudioEnabled(false)
            } label: {
                selectionLabel(L10n.noComputerAudio, isSelected: !state.isSystemAudioEnabled)
            }
            Button {
                state.setSystemAudioEnabled(true)
            } label: {
                selectionLabel(L10n.recordComputerAudio, isSelected: state.isSystemAudioEnabled)
            }
        } label: {
            Label(L10n.systemAudio, systemImage: "speaker.wave.2.fill")
        }

        Menu {
            if state.filteredLocales.isEmpty {
                let identifier = state.selectedLocale
                let name = Locale.current.localizedString(forIdentifier: identifier) ?? identifier
                Button {
                    state.selectLocale(identifier)
                } label: {
                    selectionLabel(name, isSelected: true)
                }
            } else {
                ForEach(state.filteredLocales, id: \.identifier) { locale in
                    let identifier = locale.identifier
                    let name = locale.localizedString(forIdentifier: identifier) ?? identifier
                    Button {
                        state.selectLocale(identifier)
                    } label: {
                        selectionLabel(name, isSelected: state.selectedLocale == identifier)
                    }
                }
            }
        } label: {
            Label(L10n.language, systemImage: "globe")
        }

        Menu {
            Button {
                state.selectScreenshotSource(.none)
            } label: {
                selectionLabel(L10n.notSelected, isSelected: state.screenshotCaptureSource == .none)
            }
            Divider()
            Button {
                state.selectScreenshotSource(.entireDesktop)
            } label: {
                selectionLabel(
                    L10n.entireDesktop,
                    isSelected: state.screenshotCaptureSource == .entireDesktop
                )
            }

            if !state.availableWindows.isEmpty {
                Divider()
            }

            ForEach(state.availableWindows) { window in
                Button {
                    state.selectScreenshotSource(.window(window.id))
                } label: {
                    selectionLabel(
                        window.displayName,
                        isSelected: state.screenshotCaptureSource == .window(window.id)
                    )
                }
            }
        } label: {
            Label(L10n.source, systemImage: "rectangle.on.rectangle")
        }
    }

    private func selectionLabel(_ title: String, isSelected: Bool) -> some View {
        Group {
            if isSelected {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func toggleRecording() {
        if state.isListening {
            recordingCoordinator.stopRecording()
        } else if AppSettings.shared.currentVault == nil {
            MainWindowOpener.shared.openMainWindow()
        } else {
            recordingCoordinator.startNewMeeting()
        }
    }
}
