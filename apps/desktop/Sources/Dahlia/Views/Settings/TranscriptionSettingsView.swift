import Speech
import SwiftUI

/// このMac固有の録音設定。アカウントの生成設定とは独立する。
struct TranscriptionSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var supportedLocales: [Locale] = []
    @State private var isLoadingLocales = true
    @State private var pendingShorterAudioRetentionPeriod: BatchAudioRetentionPeriod?
    @State private var isShowingAudioRetentionConfirmation = false

    var body: some View {
        Form {
            Section(L10n.transcription) {
                LabeledContent(L10n.transcriptionModel, value: "Apple Speech")
                DahliaMenuPicker(
                    title: L10n.transcriptionLanguage,
                    description: L10n.appleSpeechSettingsScopeDescription,
                    selection: transcriptionLanguageSelection,
                    options: [SettingsLanguageOptions.automaticTranscription] + SettingsLanguageOptions.locales(
                        from: supportedLocales.filter { settings.isLanguageEnabled($0.identifier) },
                        including: settings.transcriptionLocale
                    ).map(\.identifier)
                ) { identifier in
                    identifier == SettingsLanguageOptions.automaticTranscription
                        ? L10n.auto
                        : Locale(identifier: identifier).localizedString(forIdentifier: identifier) ?? identifier
                }
                .disabled(isLoadingLocales)
            }

            Section {
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
                DahliaMenuPicker(
                    title: L10n.batchTranscriptionStallTimeout,
                    description: L10n.batchTranscriptionStallTimeoutDescription,
                    selection: $settings.batchTranscriptionStallTimeout,
                    options: BatchTranscriptionStallTimeout.allCases,
                    label: \.displayName
                )
            } header: {
                Text(L10n.transcriptionRecoverySettings)
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
            supportedLocales = await SpeechSupportedLocales.load().sortedByLocalizedName()
            isLoadingLocales = false
        }
    }

    // MARK: - Private

    private var audioRetentionPeriodSelection: Binding<BatchAudioRetentionPeriod> {
        Binding(
            get: { settings.batchAudioRetentionPeriod },
            set: { applyAudioRetentionPeriodChange($0) }
        )
    }

    private var transcriptionLanguageSelection: Binding<String> {
        Binding(
            get: {
                SettingsLanguageOptions.transcriptionSelection(
                    localeIdentifier: settings.transcriptionLocale,
                    detectsAutomatically: settings.automaticTranscriptionLanguageDetectionEnabled
                )
            },
            set: { selection in
                let resolved = SettingsLanguageOptions.resolvedTranscriptionSelection(
                    selection,
                    currentLocaleIdentifier: settings.transcriptionLocale
                )
                settings.transcriptionLocale = resolved.localeIdentifier
                settings.automaticTranscriptionLanguageDetectionEnabled = resolved.detectsAutomatically
            }
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
