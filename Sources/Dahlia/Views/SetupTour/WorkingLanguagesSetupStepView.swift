import SwiftUI

struct WorkingLanguagesSetupStepView: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                AppLanguageSelectionRow()
            } header: {
                Text(L10n.recognitionAndOCRLanguages)
            } footer: {
                Text(L10n.appLanguagesDescription)
            }

            Section {
                Picker(selection: $settings.llmSummaryLanguage) {
                    ForEach(SummaryLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                } label: {
                    Text(L10n.primaryLanguage)
                    Text(L10n.primaryLanguageDescription)
                }
                .pickerStyle(.menu)
            } header: {
                Text(L10n.summaryAndCaptionLanguage)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 640)
        .frame(height: 330)
    }
}
