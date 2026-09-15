import SwiftUI

/// このMac固有の録音設定。アカウントの生成設定とは独立する。
struct TranscriptionSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var pendingShorterAudioRetentionPeriod: BatchAudioRetentionPeriod?
    @State private var isShowingAudioRetentionConfirmation = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.automaticMeetingEndRecordingStopEnabled) {
                    Text(L10n.automaticMeetingEndRecordingStop)
                    Text(L10n.automaticMeetingEndRecordingStopDescription)
                }
                .toggleStyle(.switch)
            } header: {
                Text(L10n.settingsDuringRecording)
            }

            Section {
                DisclosureGroup(L10n.settingsAutomaticExport) {
                    Toggle(isOn: $settings.exportBatchSummaryToWorkspace) {
                        Text(L10n.exportBatchSummaryToWorkspace)
                        Text(L10n.exportBatchSummaryToWorkspaceDescription)
                    }
                    .toggleStyle(.switch)
                    Toggle(isOn: $settings.exportBatchSummaryToGoogleDocs) {
                        Text(L10n.exportBatchSummaryToGoogleDocs)
                        Text(L10n.exportBatchSummaryToGoogleDocsDescription)
                    }
                    .toggleStyle(.switch)
                }
            } header: {
                Text(L10n.settingsAfterRecording)
            }

            Section {
                DahliaMenuPicker(
                    title: L10n.batchAudioRetentionPeriod,
                    description: L10n.batchAudioRetentionPeriodDescription,
                    selection: audioRetentionPeriodSelection,
                    options: BatchAudioRetentionPeriod.allCases,
                    label: \.displayName
                )
            } header: {
                Text(L10n.settingsAudioStorage)
            }

            Section {
                DisclosureGroup(L10n.advanced) {
                    DahliaMenuPicker(
                        title: L10n.batchTranscriptionStallTimeout,
                        description: L10n.batchTranscriptionStallTimeoutDescription,
                        selection: $settings.batchTranscriptionStallTimeout,
                        options: BatchTranscriptionStallTimeout.allCases,
                        label: \.displayName
                    )
                    Toggle(isOn: $settings.forceEchoCancellationForExternalMicrophone) {
                        Text(L10n.externalMicrophoneEchoCancellation)
                        Text(L10n.externalMicrophoneEchoCancellationDescription)
                    }
                    .toggleStyle(.switch)
                    Text(L10n.builtInMicrophoneEchoCancellationDescription).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            L10n.shortenBatchAudioRetentionPeriodTitle,
            isPresented: $isShowingAudioRetentionConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.apply, role: .destructive, action: confirmShorterAudioRetentionPeriod)
            Button(L10n.cancel, role: .cancel, action: cancelShorterAudioRetentionPeriod)
        } message: {
            Text(L10n.shortenBatchAudioRetentionPeriodMessage)
        }
    }

    // MARK: - Private

    private var audioRetentionPeriodSelection: Binding<BatchAudioRetentionPeriod> {
        Binding(
            get: { settings.batchAudioRetentionPeriod },
            set: { applyAudioRetentionPeriodChange($0) }
        )
    }

    private func applyAudioRetentionPeriodChange(_ newValue: BatchAudioRetentionPeriod) {
        guard newValue != settings.batchAudioRetentionPeriod else { return }
        guard newValue.isShorter(than: settings.batchAudioRetentionPeriod) else {
            settings.batchAudioRetentionPeriod = newValue
            return
        }
        pendingShorterAudioRetentionPeriod = newValue
        Task { @MainActor in
            await Task.yield()
            guard pendingShorterAudioRetentionPeriod == newValue else { return }
            isShowingAudioRetentionConfirmation = true
        }
    }

    private func confirmShorterAudioRetentionPeriod() {
        guard let pendingShorterAudioRetentionPeriod else { return }
        settings.batchAudioRetentionPeriod = pendingShorterAudioRetentionPeriod
        self.pendingShorterAudioRetentionPeriod = nil
    }

    private func cancelShorterAudioRetentionPeriod() {
        pendingShorterAudioRetentionPeriod = nil
    }

}
