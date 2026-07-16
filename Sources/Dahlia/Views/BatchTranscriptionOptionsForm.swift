import SwiftUI

struct BatchTranscriptionOptionsForm: View {
    let locales: [Locale]
    @Binding var selectedLocaleIdentifier: String
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
                Picker(L10n.language, selection: $selectedLocaleIdentifier) {
                    ForEach(locales, id: \.identifier) { locale in
                        Text(displayName(for: locale)).tag(locale.identifier)
                    }
                }
                .pickerStyle(.menu)

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
                .toggleStyle(.checkbox)

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
        locale.localizedString(forIdentifier: locale.identifier)
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
