import Speech
import SwiftUI

/// このMac固有の文字起こし設定。
struct TranscriptionSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var supportedLocales: [Locale] = []
    @State private var isLoadingLocales = true

    var body: some View {
        Form {
            Section {
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
                LabeledContent(L10n.transcriptionModel, value: "Apple Speech")
            } header: {
                Text(L10n.transcription)
                    .font(.dahliaSectionHeader)
            }

            Section {
                Toggle(isOn: $settings.exportBatchSummaryToWorkspace) {
                    Text(L10n.exportBatchSummaryToWorkspace)
                    Text(L10n.exportBatchSummaryToWorkspaceDescription)
                }
                .toggleStyle(.switch)
            } header: {
                Text(L10n.settingsAfterRecording)
                    .font(.dahliaSectionHeader)
            }

        }
        .formStyle(.grouped)
        .font(.dahliaBody)
        .task {
            supportedLocales = await SpeechSupportedLocales.load().sortedByLocalizedName()
            isLoadingLocales = false
        }
    }

    // MARK: - Private

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

}
