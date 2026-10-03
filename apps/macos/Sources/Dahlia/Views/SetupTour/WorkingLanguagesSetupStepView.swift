import SwiftUI

struct WorkingLanguagesSetupStepView: View {
    var body: some View {
        Form {
            Section {
                AppLanguageSelectionRow()
            } header: {
                Text(L10n.recognitionAndOCRLanguages)
            } footer: {
                Text(L10n.appLanguagesDescription)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 640)
        .frame(height: 330)
    }
}
