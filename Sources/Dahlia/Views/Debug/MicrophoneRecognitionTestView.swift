import CoreAudio
import SwiftUI

struct MicrophoneRecognitionTestView: View {
    @ObservedObject var captionViewModel: CaptionViewModel
    @State private var model = MicrophoneRecognitionTestModel()

    var body: some View {
        Form {
            Section {
                Picker(L10n.microphone, selection: $model.selectedDeviceID) {
                    Text(L10n.sameAsSystem).tag(nil as AudioDeviceID?)
                    ForEach(model.devices) { device in
                        Text(device.name).tag(Optional(device.id))
                    }
                }
                .disabled(model.isActive)

                Button(
                    model.isActive ? L10n.stopAudioRecognitionTest : L10n.startAudioRecognitionTest,
                    systemImage: model.isActive ? "stop.fill" : "waveform.and.mic",
                    action: toggleTest
                )
                .disabled(captionViewModel.isListening && !model.isActive)

                if captionViewModel.isListening, !model.isActive {
                    SettingsStatusMessage(
                        text: L10n.stopRecordingBeforeAudioTest,
                        systemImage: "exclamationmark.triangle",
                        tint: .orange
                    )
                }
            } header: {
                Text(L10n.audioRecognitionTest)
            } footer: {
                Text(L10n.audioRecognitionTestDescription)
            }

            Section {
                LabeledContent(L10n.preferredMicrophoneMode, value: model.preferredMicrophoneModeText)
                LabeledContent(L10n.activeMicrophoneMode, value: model.activeMicrophoneModeText)

                Button(
                    L10n.openMicrophoneModes,
                    systemImage: "mic.badge.plus",
                    action: model.showMicrophoneModes
                )
            } header: {
                Text(L10n.systemMicrophoneMode)
            } footer: {
                Text(L10n.systemMicrophoneModeDescription)
            }

            if !model.captureDiagnostics.isEmpty {
                Section {
                    ForEach(model.captureDiagnostics) { snapshot in
                        MicrophoneCaptureDiagnosticRowView(
                            title: model.captureDiagnosticTitle(snapshot),
                            timestamp: model.captureDiagnosticTimestamp(snapshot),
                            details: model.captureDiagnosticDetails(snapshot)
                        )
                    }
                } header: {
                    Text(L10n.microphoneCaptureLog)
                } footer: {
                    Text(L10n.microphoneCaptureLogDescription)
                }
            }

            Section(L10n.audioRecognitionTestStatus) {
                LabeledContent(L10n.status, value: model.statusText)

                LabeledContent(L10n.inputLevel) {
                    ProgressView(value: model.inputLevel)
                        .accessibilityValue(Text(model.inputLevel, format: .percent.precision(.fractionLength(0))))
                }

                LabeledContent(L10n.audioBuffers, value: model.bufferCount.formatted())

                ForEach(Array(model.inputChannelLevels.enumerated()), id: \.offset) { index, level in
                    LabeledContent(L10n.inputChannel(index + 1)) {
                        ProgressView(value: level)
                            .accessibilityValue(Text(level, format: .percent.precision(.fractionLength(0))))
                    }
                }

                if let startInfo = model.startInfo {
                    LabeledContent(L10n.hardwareFormat, value: startInfo.hardwareFormatDescription)
                    LabeledContent(L10n.inputFormat, value: startInfo.sourceFormatDescription)
                    LabeledContent(L10n.recognitionFormat, value: startInfo.targetFormatDescription)
                }

                if let errorMessage = model.errorMessage {
                    SettingsStatusMessage(
                        text: errorMessage,
                        systemImage: "exclamationmark.triangle",
                        tint: .red
                    )
                }
            }

            Section(L10n.recognizedText) {
                if model.displayedTranscript.isEmpty {
                    Text(L10n.speakIntoSelectedMicrophone)
                        .foregroundStyle(.secondary)
                } else {
                    Text(model.displayedTranscript)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .task {
            model.refreshDevices()
            await model.monitorMicrophoneModes()
        }
        .onDisappear(perform: stopTest)
        .onChange(of: captionViewModel.isListening) { _, isListening in
            if isListening {
                stopTest()
            }
        }
    }

    private func toggleTest() {
        Task {
            await model.toggle()
        }
    }

    private func stopTest() {
        Task {
            await model.stop()
        }
    }
}
