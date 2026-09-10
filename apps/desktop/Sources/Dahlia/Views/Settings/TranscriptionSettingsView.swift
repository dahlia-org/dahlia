import Speech
import SwiftUI

/// このMac固有の録音設定。アカウントの生成設定とは独立する。
struct TranscriptionSettingsView: View {
    let onOpenAccountSettings: () -> Void
    @ObservedObject private var settings = AppSettings.shared
    @State private var supportedLocales: [Locale] = []
    @State private var isLoadingLocales = true
    @State private var pendingShorterAudioRetentionPeriod: BatchAudioRetentionPeriod?
    @State private var isShowingAudioRetentionConfirmation = false

    var body: some View {
        Form {
            Section {
                Toggle(L10n.liveTranscriptDraft, isOn: $settings.liveTranscriptDraftEnabled)
                    .toggleStyle(.switch)
                DahliaMenuPicker(
                    title: L10n.transcriptionLanguage,
                    description: L10n.transcriptionLanguageDescription,
                    selection: $settings.transcriptionLocale,
                    options: transcriptionLocaleOptions.map(\.identifier)
                ) { identifier in
                    Locale(identifier: identifier).localizedString(forIdentifier: identifier) ?? identifier
                }
                .disabled(isLoadingLocales)

                Toggle(isOn: $settings.automaticMeetingEndRecordingStopEnabled) {
                    Text(L10n.automaticMeetingEndRecordingStop)
                    Text(L10n.automaticMeetingEndRecordingStopDescription)
                }
                .toggleStyle(.switch)
            } header: {
                Text(L10n.settingsDuringRecording)
            }

            Section {
                Toggle(L10n.automaticRecordingProcessing, isOn: $settings.automaticRecordingProcessingEnabled)
                    .toggleStyle(.switch)
                Button(L10n.settingsChooseSummaryPreferences, systemImage: "arrow.right", action: onOpenAccountSettings)
                DisclosureGroup(L10n.settingsAutomaticExport) {
                    Toggle(isOn: $settings.exportBatchSummaryToVault) {
                        Text(L10n.exportBatchSummaryToVault)
                        Text(L10n.exportBatchSummaryToVaultDescription)
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
        .task {
            await loadSupportedLocales()
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

    private var transcriptionLocaleOptions: [Locale] {
        SettingsLanguageOptions.locales(
            from: supportedLocales.filter { settings.isLanguageEnabled($0.identifier) },
            including: settings.transcriptionLocale
        )
    }

    private func loadSupportedLocales() async {
        isLoadingLocales = true
        let locales = await SpeechSupportedLocales.load()
        supportedLocales = locales.sortedByLocalizedName()
        isLoadingLocales = false
    }
}
