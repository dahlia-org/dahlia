import SwiftUI

struct BatchTranscriptionOptionsForm: View {
    let locales: [Locale]
    let automaticLanguageLocales: [Locale]
    let displayLocale: Locale
    let allowsRecordedLanguageSelection: Bool
    @Binding var languageSelection: BatchTranscriptionLanguageSelection
    @Binding var generateSummaryAfterBatchTranscription: Bool
    @Binding var summaryDetailLevel: SummaryDetailLevel?
    @Binding var exportBatchSummaryToWorkspace: Bool
    @Binding var exportBatchSummaryToGoogleDocs: Bool
    let projects: [FlatProjectRow]
    @Binding var selectedProjectId: UUID?
    var processingMethod: RecordingProcessingMethod?
    let usesServerSummary: Bool
    let isRetranscription: Bool

    var body: some View {
        Form {
            if isRetranscription {
                Section(L10n.retranscription) {
                    LabeledContent(
                        L10n.processingMethod,
                        value: usesServerSummary ? L10n.retranscriptionGemini : L10n.retranscriptionAppleSpeech
                    )
                    Text(usesServerSummary
                        ? L10n.serverRetranscriptionPolicyDescription
                        : L10n.localRetranscriptionPolicyDescription)
                        .foregroundStyle(.secondary)
                    Text(L10n.retranscriptionKeepsSummary)
                        .foregroundStyle(.secondary)
                }
            } else if let processingMethod {
                Section { LabeledContent(L10n.processingMethod, value: processingMethod.displayName) }
            }
            if !isRetranscription, processingMethod == nil || processingMethod == .transcript {
                Section(L10n.transcription) {
                    Picker(L10n.language, selection: $languageSelection) {
                        if allowsRecordedLanguageSelection {
                            Text(L10n.recordedLanguages)
                                .tag(BatchTranscriptionLanguageSelection.recorded)
                        }

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

                }

            }
            if !isRetranscription {
                Section(L10n.summaryAndExport) {
                    SummaryProjectPicker(projects: projects, selection: $selectedProjectId)

                    if processingMethod == nil {
                        Toggle(isOn: $generateSummaryAfterBatchTranscription) {
                            Text(L10n.generateSummaryAfterBatchTranscription)
                            Text(L10n.generateSummaryAfterBatchTranscriptionDescription)
                        }
                        .toggleStyle(.switch)
                    }

                    SummaryGenerationOptionsControls(
                        detailLevel: $summaryDetailLevel,
                        exportsToWorkspace: $exportBatchSummaryToWorkspace,
                        exportsToGoogleDocs: $exportBatchSummaryToGoogleDocs,
                        isEnabled: processingMethod != nil || generateSummaryAfterBatchTranscription,
                        usesServerSummary: usesServerSummary
                    )
                }
            }
        }
        .formStyle(.grouped)
    }

    private func displayName(for locale: Locale) -> String {
        displayLocale.localizedString(forIdentifier: locale.identifier)
            ?? Locale.current.localizedString(forIdentifier: locale.identifier)
            ?? locale.identifier
    }

}
