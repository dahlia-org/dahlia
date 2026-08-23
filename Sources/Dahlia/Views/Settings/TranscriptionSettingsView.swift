import Speech
import SwiftUI

/// 設定画面「文字起こし」タブ。認識方法と利用する言語を管理する。
struct TranscriptionSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var supportedLocales: [Locale] = []
    @State private var isLoadingLocales = true

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

            if settings.transcriptionMode == .batch {
                Section {
                    DahliaMenuPicker(
                        title: L10n.batchTranscriptionStallTimeout,
                        description: L10n.batchTranscriptionStallTimeoutDescription,
                        selection: $settings.batchTranscriptionStallTimeout,
                        options: BatchTranscriptionStallTimeout.allCases,
                        label: \.displayName
                    )

                    Toggle(isOn: $settings.retainAudioAfterBatchTranscription) {
                        Text(L10n.retainBatchAudio)
                        Text(L10n.retainBatchAudioDescription)
                    }
                    .toggleStyle(.switch)

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
