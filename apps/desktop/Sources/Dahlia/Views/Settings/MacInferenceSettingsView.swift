import SwiftUI

struct MacInferenceSettingsView: View {
    var body: some View {
        Form {
            AccountSettingsView()
            LocalSummarySettingsSection()
        }
        .formStyle(.grouped)
    }
}
