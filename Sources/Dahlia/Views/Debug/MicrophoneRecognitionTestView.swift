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
                Text(model.capturePathDescription)
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

                if model.showsRawInputLevel {
                    LabeledContent(L10n.rawInputLevel) {
                        ProgressView(value: model.rawInputLevel)
                            .accessibilityValue(Text(model.rawInputLevel, format: .percent.precision(.fractionLength(0))))
                    }
                }

                if model.showsProcessedInputLevel {
                    LabeledContent(L10n.processedInputLevel) {
                        ProgressView(value: model.processedInputLevel)
                            .accessibilityValue(Text(model.processedInputLevel, format: .percent.precision(.fractionLength(0))))
                    }
                }

                if model.showsReferenceInputLevel {
                    LabeledContent(L10n.referenceInputLevel) {
                        ProgressView(value: model.referenceInputLevel)
                            .accessibilityValue(Text(
                                model.referenceInputLevel,
                                format: .percent.precision(.fractionLength(0))
                            ))
                    }
                    LabeledContent(L10n.referenceAudioBuffers, value: model.referenceBufferCount.formatted())
                }

                LabeledContent(L10n.audioBuffers, value: model.bufferCount.formatted())

                ForEach(model.inputChannelLevels.enumerated(), id: \.offset) { index, level in
                    LabeledContent(L10n.inputChannel(index + 1)) {
                        ProgressView(value: level)
                            .accessibilityValue(Text(level, format: .percent.precision(.fractionLength(0))))
                    }
                }

                if let startInfo = model.startInfo {
                    LabeledContent(L10n.hardwareFormat, value: startInfo.hardwareFormatDescription)
                    LabeledContent(L10n.inputFormat, value: startInfo.sourceFormatDescription)
                    LabeledContent(L10n.recognitionFormat, value: startInfo.targetFormatDescription)
                    if let processingLatencyText = model.processingLatencyText {
                        LabeledContent(L10n.processingLatency, value: processingLatencyText)
                    }
                    if let statistics = model.echoCancellationStatistics {
                        LabeledContent(
                            L10n.echoCancellationDelay,
                            value: statistics.delayMilliseconds.map { "\($0) ms" } ?? L10n.notAvailable
                        )
                        LabeledContent(
                            L10n.echoCancellationERLE,
                            value: statistics.echoReturnLossEnhancement.map {
                                $0.formatted(.number.precision(.fractionLength(1))) + " dB"
                            } ?? L10n.notAvailable
                        )
                        LabeledContent(
                            L10n.residualEchoLikelihood,
                            value: statistics.residualEchoLikelihood.map {
                                $0.formatted(.percent.precision(.fractionLength(1)))
                            } ?? L10n.notAvailable
                        )
                        LabeledContent(
                            L10n.streamDelayHint,
                            value: statistics.streamDelayHintMilliseconds.map { "\($0) ms" } ?? L10n.notAvailable
                        )
                        LabeledContent(
                            L10n.presentationTimeDelta,
                            value: millisecondsText(statistics.presentationTimeDeltaMilliseconds)
                        )
                        LabeledContent(
                            L10n.referenceCallbackLatency,
                            value: millisecondsText(statistics.referenceCallbackLatencyMilliseconds)
                        )
                        LabeledContent(
                            L10n.captureCallbackLatency,
                            value: millisecondsText(statistics.captureCallbackLatencyMilliseconds)
                        )
                        LabeledContent(
                            L10n.renderFrameLead,
                            value: millisecondsText(statistics.renderFrameLeadMilliseconds)
                        )
                        LabeledContent(
                            L10n.referenceAudioFrames,
                            value: statistics.referenceFrameCount.formatted()
                        )
                        LabeledContent(
                            L10n.captureAudioFrames,
                            value: statistics.captureFrameCount.formatted()
                        )
                        LabeledContent(
                            L10n.captureWithoutReferenceFrames,
                            value: statistics.captureWithoutReferenceFrameCount.formatted()
                        )
                    }
                }

                if let errorMessage = model.errorMessage {
                    SettingsStatusMessage(
                        text: errorMessage,
                        systemImage: "exclamationmark.triangle",
                        tint: .red
                    )
                }
            }

            if let diagnosticOutputDirectory = model.diagnosticOutputDirectory {
                Section {
                    LabeledContent(L10n.temporaryAudioFolder, value: diagnosticOutputDirectory.path(percentEncoded: false))
                    Button(
                        L10n.showTemporaryAudioInFinder,
                        systemImage: "folder",
                        action: model.showDiagnosticOutputDirectory
                    )
                } header: {
                    Text(L10n.diagnosticAudioOutput)
                } footer: {
                    Text(model.diagnosticAudioOutputDescription)
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
            await model.monitorDiagnostics()
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

    private func millisecondsText(_ milliseconds: Double?) -> String {
        guard let milliseconds else { return L10n.notAvailable }
        return milliseconds.formatted(.number.precision(.fractionLength(1))) + " ms"
    }
}
