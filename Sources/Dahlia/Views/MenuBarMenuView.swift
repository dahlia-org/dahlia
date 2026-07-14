import AppKit
import SwiftUI

struct MenuBarMenuView: View {
    @ObservedObject var viewModel: CaptionViewModel
    let recordingCoordinator: RecordingCoordinator

    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @AppStorage("liveSubtitleOverlayEnabled") private var liveSubtitleOverlayEnabled = false

    var body: some View {
        VStack {
            if viewModel.isListening {
                Button {
                    recordingCoordinator.stopRecording()
                } label: {
                    Label(L10n.menuBarStopRecording, systemImage: "stop.fill")
                }
            } else {
                Button {
                    startRecording()
                } label: {
                    Label(L10n.menuBarStartRecording, systemImage: "record.circle")
                }
                .disabled(!recordingCoordinator.canStartNewMeeting && AppSettings.shared.currentVault != nil)
            }

            Toggle(isOn: $liveSubtitleOverlayEnabled) {
                Label(L10n.menuBarShowLiveSubtitles, systemImage: "text.bubble")
            }

            Divider()

            recordingSettingsMenus

            Divider()

            Button {
                MainWindowOpener.shared.openMainWindow()
            } label: {
                Label(L10n.menuBarOpenDahlia, systemImage: "macwindow")
            }

            Button {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: WindowID.projectManager)
            } label: {
                Label(L10n.manageProjects, systemImage: "folder")
            }

            Divider()

            Button {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            } label: {
                Label(L10n.settingsMenuItem, systemImage: "gearshape")
            }
            .keyboardShortcut(",", modifiers: .command)

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label(L10n.menuBarQuitDahlia, systemImage: "power")
            }
            .keyboardShortcut("q", modifiers: .command)
        }
        .onAppear {
            MainWindowOpener.shared.register(openWindow: openWindow)
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
        }
        .task {
            await viewModel.refreshAvailableMicrophones()
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
        }
        .onAppear {
            viewModel.refreshAvailableWindows()
        }
    }

    private func startRecording() {
        if AppSettings.shared.currentVault == nil {
            MainWindowOpener.shared.openMainWindow()
        } else {
            recordingCoordinator.startNewMeeting()
        }
    }
}

struct MenuBarLabel: View {
    @ObservedObject var viewModel: CaptionViewModel

    var body: some View {
        Label {
            Text("Dahlia")
        } icon: {
            Image(systemName: viewModel.isListening ? "record.circle.fill" : "waveform")
        }
    }
}
