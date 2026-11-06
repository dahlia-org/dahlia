import SwiftUI

struct ModelProviderSetupStepView: View {
    var body: some View {
        Form {
            AccountSettingsView()
        }
        .formStyle(.grouped)
        .frame(height: 480)
    }
}
