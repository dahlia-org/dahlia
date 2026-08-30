import CoreAudio
import SwiftUI

struct MicrophoneInputVolumeControl: View {
    @ObservedObject var viewModel: CaptionViewModel
    let deviceID: AudioDeviceID

    @State private var isPresented = false
    @State private var inputVolume = 0.0
    @State private var isLoading = true
    @State private var isVolumeAvailable = false
    @State private var errorMessage: String?

    var body: some View {
        Button(L10n.adjustMicrophoneInputVolume, systemImage: "slider.horizontal.3") {
            isPresented = true
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .controlSize(.small)
        .help(L10n.adjustMicrophoneInputVolume)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.builtInMicrophoneInputVolume)
                    .font(.headline)

                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                } else {
                    HStack {
                        Slider(value: $inputVolume, in: 0 ... 1) { isEditing in
                            if !isEditing {
                                updateInputVolume()
                            }
                        }
                        .disabled(!isVolumeAvailable)
                        .accessibilityLabel(L10n.builtInMicrophoneInputVolume)
                        .accessibilityValue(inputVolume.formatted(.percent.precision(.fractionLength(0))))

                        Text(inputVolume, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit()
                            .frame(minWidth: 40, alignment: .trailing)
                    }

                    if !isVolumeAvailable {
                        Text(L10n.inputVolumeUnavailable)
                            .foregroundStyle(.secondary)
                    }
                }

                Text(L10n.builtInMicrophoneInputVolumeDescription)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                Button(action: openSoundSettings) {
                    Label(L10n.openSoundSettings, systemImage: "gear")
                        .frame(maxWidth: .infinity)
                }
            }
            .padding()
            .frame(width: 300)
            .task(id: deviceID) {
                await loadInputVolume()
            }
        }
    }

    private func updateInputVolume() {
        guard isVolumeAvailable else { return }
        let volume = Float(inputVolume)
        Task {
            guard await viewModel.setInputVolume(volume, for: deviceID) else {
                if let currentState = await viewModel.inputVolumeState(for: deviceID) {
                    inputVolume = Double(currentState.value)
                }
                isVolumeAvailable = false
                errorMessage = L10n.inputVolumeUpdateFailed
                return
            }
            errorMessage = nil
        }
    }

    private func loadInputVolume() async {
        isLoading = true
        isVolumeAvailable = false
        errorMessage = nil
        guard let state = await viewModel.inputVolumeState(for: deviceID) else {
            isLoading = false
            return
        }
        inputVolume = Double(state.value)
        isVolumeAvailable = state.isSettable
        isLoading = false
    }

    private func openSoundSettings() {
        guard SystemSettingsOpener().openSoundInputSettings() else {
            errorMessage = L10n.soundSettingsOpenFailed
            return
        }
        errorMessage = nil
    }
}
