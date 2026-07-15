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

                Toggle(isOn: $exportBatchSummaryToVault) {
                    Text(L10n.exportBatchSummaryToVault)
                    Text(L10n.exportBatchSummaryToVaultDescription)
                }
                .toggleStyle(.checkbox)
                .disabled(!generateSummaryAfterBatchTranscription)

                Toggle(isOn: $exportBatchSummaryToGoogleDocs) {
                    Text(L10n.exportBatchSummaryToGoogleDocs)
                    Text(L10n.exportBatchSummaryToGoogleDocsDescription)
                }
                .toggleStyle(.checkbox)
                .disabled(!generateSummaryAfterBatchTranscription)
            }
        }
        .formStyle(.grouped)
    }

    private func displayName(for locale: Locale) -> String {
        locale.localizedString(forIdentifier: locale.identifier)
            ?? Locale.current.localizedString(forIdentifier: locale.identifier)
            ?? locale.identifier
    }
}
