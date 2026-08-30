import SwiftUI

struct PermissionSetupStepView: View {
    static let permissions: [AppPermission] = [.screenAndSystemAudio, .microphone]

    var body: some View {
        PermissionSettingsView(
            permissions: Self.permissions,
            showsDescription: false,
            showsPermissionFooters: false,
            prominentLabels: true
        )
        .frame(height: 390)
    }
}
