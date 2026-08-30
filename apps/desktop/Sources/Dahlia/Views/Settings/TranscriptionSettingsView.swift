import Speech
import SwiftUI

/// 設定画面「文字起こし」タブ。認識方法と利用する言語を管理する。
struct TranscriptionSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var supportedLocales: [Locale] = []
    @State private var isLoadingLocales = true
    @State private var pendingShorterAudioRetentionPeriod: BatchAudioRetentionPeriod?
    @State private var isShowingAudioRetentionConfirmation = false

    var body: some View {
        Form {
            Section {
                DahliaSegmentedPicker(
                    title: L10n.transcriptionMethod,
                    selection: $settings.transcriptionMode,
                    options: TranscriptionMode.allCases,
                    label: \.displayName
                )
            } footer: {
                Text(transcriptionModeDescription)
            }

            if settings.transcriptionMode == .batch {
                Section {
                    DahliaMenuPicker(
                        title: L10n.transcriptionLanguage,
                        selection: $settings.transcriptionLocale,
                        options: transcriptionLocaleOptions.map(\.identifier)
                    ) { identifier in
                        Locale(identifier: identifier).localizedString(forIdentifier: identifier) ?? identifier
                    }
                    .disabled(isLoadingLocales)
                } footer: {
                    Text(L10n.transcriptionLanguageDescription)
                }

                Section {
                    DahliaMenuPicker(
                        title: L10n.batchTranscriptionStallTimeout,
                        description: L10n.batchTranscriptionStallTimeoutDescription,
                        selection: $settings.batchTranscriptionStallTimeout,
                        options: BatchTranscriptionStallTimeout.allCases,
                        label: \.displayName
                    )

                    DahliaMenuPicker(
                        title: L10n.batchAudioRetentionPeriod,
                        description: L10n.batchAudioRetentionPeriodDescription,
                        selection: audioRetentionPeriodSelection,
                        options: BatchAudioRetentionPeriod.allCases,
                        label: \.displayName
                    )

                    Toggle(isOn: $settings.generateSummaryAfterBatchTranscription) {
                        Text(L10n.generateSummaryAfterBatchTranscription)
                        Text(L10n.generateSummaryAfterBatchTranscriptionDescription)
                    }
                    .toggleStyle(.switch)

                    Toggle(isOn: $settings.exportBatchSummaryToVault) {
                        Text(L10n.exportBatchSummaryToVault)
                        Text(L10n.exportBatchSummaryToVaultDescription)
                    }
                    .toggleStyle(.switch)
                    .disabled(!settings.generateSummaryAfterBatchTranscription)

                    Toggle(isOn: $settings.exportBatchSummaryToGoogleDocs) {
                        Text(L10n.exportBatchSummaryToGoogleDocs)
                        Text(L10n.exportBatchSummaryToGoogleDocsDescription)
                    }
                    .toggleStyle(.switch)
                    .disabled(!settings.generateSummaryAfterBatchTranscription)
                } header: {
                    Text(L10n.batchTranscription)
                }
            }

            Section {
                Toggle(isOn: $settings.forceEchoCancellationForExternalMicrophone) {
                    Text(L10n.externalMicrophoneEchoCancellation)
                    Text(L10n.externalMicrophoneEchoCancellationDescription)
                }
                .toggleStyle(.switch)
            } header: {
                Text(L10n.audioInput)
            } footer: {
                Text(L10n.builtInMicrophoneEchoCancellationDescription)
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

    private var transcriptionModeDescription: String {
        switch settings.transcriptionMode {
        case .realtime: L10n.realtimeTranscriptionDescription
        case .batch: L10n.batchTranscriptionDescription
        }
    }

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
        var locales = supportedLocales.filter { settings.isLanguageEnabled($0.identifier) }
        if !locales.contains(where: { $0.identifier == settings.transcriptionLocale }) {
            locales.append(Locale(identifier: settings.transcriptionLocale))
        }
        return locales.sortedByLocalizedName()
    }

    private func loadSupportedLocales() async {
        isLoadingLocales = true
        let locales = await SpeechSupportedLocales.load()
        supportedLocales = locales.sortedByLocalizedName()
        isLoadingLocales = false
    }
}
