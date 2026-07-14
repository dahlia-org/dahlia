import SwiftUI

struct MenuBarRecordingControls: View {
    @ObservedObject var viewModel: CaptionViewModel
    let recordingCoordinator: RecordingCoordinator

    @AppStorage("liveSubtitleOverlayEnabled") private var liveSubtitleOverlayEnabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: toggleRecording) {
                Label(
                    viewModel.isListening ? L10n.menuBarStopRecording : L10n.menuBarStartRecording,
                    systemImage: viewModel.isListening ? "stop.fill" : "record.circle"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(viewModel.isListening ? .red : .accentColor)
            .disabled(!viewModel.isListening && !recordingCoordinator.canStartNewMeeting && AppSettings.shared.currentVault != nil)

            Toggle(isOn: $liveSubtitleOverlayEnabled) {
                Label(L10n.menuBarShowLiveSubtitles, systemImage: "text.bubble")
            }
            .toggleStyle(.switch)

            recordingSettingsMenus
        }
        .padding()
        .onAppear {
            viewModel.refreshAvailableWindows()
        }
        .task {
            await viewModel.refreshAvailableMicrophones()
        }
    }

    @ViewBuilder
    private var recordingSettingsMenus: some View {
        Menu {
            Picker(selection: $viewModel.microphoneSelection) {
                Text(L10n.none).tag(MicrophoneSelection.none)
                Divider()
                Text(viewModel.systemDefaultMicrophoneTitle).tag(MicrophoneSelection.systemDefault)

                if !viewModel.availableMicrophones.isEmpty {
                    Divider()
                }

                ForEach(viewModel.availableMicrophones) { microphone in
                    Text(microphone.name).tag(MicrophoneSelection.device(microphone.id))
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.inline)
            .labelsHidden()
            .onChange(of: viewModel.microphoneSelection) { oldValue, newValue in
                viewModel.handleMicrophoneSelectionChange(from: oldValue, to: newValue)
            }
        } label: {
            Label(L10n.microphone, systemImage: "mic.fill")
                .frame(maxWidth: .infinity, alignment: .leading)
        }

        Menu {
            Picker(selection: $viewModel.isSystemAudioEnabled) {
                Text(L10n.noComputerAudio).tag(false)
                Text(L10n.recordComputerAudio).tag(true)
            } label: {
                EmptyView()
            }
            .pickerStyle(.inline)
            .labelsHidden()
            .onChange(of: viewModel.isSystemAudioEnabled) { oldValue, newValue in
                viewModel.handleSystemAudioSelectionChange(from: oldValue, to: newValue)
            }
        } label: {
            Label(L10n.systemAudio, systemImage: "speaker.wave.2.fill")
                .frame(maxWidth: .infinity, alignment: .leading)
        }

        Menu {
            Picker(selection: $viewModel.selectedLocale) {
                if viewModel.filteredLocales.isEmpty {
                    let id = viewModel.selectedLocale
                    let name = Locale.current.localizedString(forIdentifier: id) ?? id
                    Text(name).tag(id)
                } else {
                    ForEach(viewModel.filteredLocales, id: \.identifier) { locale in
                        let id = locale.identifier
                        let name = locale.localizedString(forIdentifier: id) ?? id
                        Text(name).tag(id)
                    }
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Label(L10n.language, systemImage: "globe")
                .frame(maxWidth: .infinity, alignment: .leading)
        }

        Menu {
            Picker(selection: $viewModel.screenshotCaptureSource) {
                Text(L10n.notSelected).tag(ScreenshotCaptureSource.none)
                Divider()
                Text(L10n.entireDesktop).tag(ScreenshotCaptureSource.entireDesktop)

                if !viewModel.availableWindows.isEmpty {
                    Divider()
                }

                ForEach(viewModel.availableWindows) { window in
                    Text(window.displayName).tag(ScreenshotCaptureSource.window(window.id))
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Label(L10n.source, systemImage: "rectangle.on.rectangle")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func toggleRecording() {
        if viewModel.isListening {
            recordingCoordinator.stopRecording()
        } else if AppSettings.shared.currentVault == nil {
            MainWindowOpener.shared.openMainWindow()
        } else {
            recordingCoordinator.startNewMeeting()
        }
    }
}
