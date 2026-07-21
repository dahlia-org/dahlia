import SwiftUI

struct BatchTranscriptionOptionsForm: View {
    let locales: [Locale]
    let automaticLanguageLocales: [Locale]
    let displayLocale: Locale
    @Binding var languageSelection: BatchTranscriptionLanguageSelection
    @Binding var deleteAudioAfterTranscription: Bool

    @AppStorage(AppSettings.generateSummaryAfterBatchTranscriptionUserDefaultsKey)
    private var generateSummaryAfterBatchTranscription = false
    @AppStorage(AppSettings.exportBatchSummaryToVaultUserDefaultsKey)
    private var exportBatchSummaryToVault = true
    @AppStorage(AppSettings.exportBatchSummaryToGoogleDocsUserDefaultsKey)
    private var exportBatchSummaryToGoogleDocs = false
    @AppStorage(AppSettings.summaryPreviousMeetingCountUserDefaultsKey)
    private var previousMeetingCount = AppSettings.defaultSummaryPreviousMeetingCount

    var body: some View {
        Form {
            Section(L10n.transcription) {
                Picker(L10n.language, selection: $languageSelection) {
                    Text(L10n.auto)
                        .tag(BatchTranscriptionLanguageSelection.automatic)
                        .disabled(automaticLanguageLocales.isEmpty)

                    ForEach(locales, id: \.identifier) { locale in
                        Text(displayName(for: locale))
                            .tag(BatchTranscriptionLanguageSelection.manual(localeIdentifier: locale.identifier))
                    }
                }
                .pickerStyle(.menu)

                if languageSelection == .automatic {
                    BatchAutomaticLanguageDetectionNotice(
                        locales: automaticLanguageLocales,
                        displayLocale: displayLocale
                    )
                }

                Toggle(isOn: $deleteAudioAfterTranscription) {
                    Text(L10n.deleteBatchAudioAfterTranscription)
                    Text(L10n.deleteBatchAudioAfterTranscriptionDescription)
                }
                .toggleStyle(.checkbox)
            }

            Section(L10n.summaryAndExport) {
                Toggle(isOn: $generateSummaryAfterBatchTranscription) {
                    Text(L10n.generateSummaryAfterBatchTranscription)
                    Text(L10n.generateSummaryAfterBatchTranscriptionDescription)
                }
                .toggleStyle(.switch)

                SummaryGenerationOptionsControls(
                    previousMeetingCount: normalizedPreviousMeetingCount,
                    exportsToVault: $exportBatchSummaryToVault,
                    exportsToGoogleDocs: $exportBatchSummaryToGoogleDocs,
                    isEnabled: generateSummaryAfterBatchTranscription
                )
            }
        }
        .formStyle(.grouped)
    }

    private func displayName(for locale: Locale) -> String {
        displayLocale.localizedString(forIdentifier: locale.identifier)
            ?? Locale.current.localizedString(forIdentifier: locale.identifier)
            ?? locale.identifier
    }

    private var normalizedPreviousMeetingCount: Binding<Int> {
        Binding(
            get: { AppSettings.normalizedSummaryPreviousMeetingCount(previousMeetingCount) },
            set: { previousMeetingCount = AppSettings.normalizedSummaryPreviousMeetingCount($0) }
        )
    }
}
