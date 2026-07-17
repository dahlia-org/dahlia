import SwiftUI

struct DatabricksProfilePicker: View {
    @Binding var selection: String
    let profiles: [DatabricksCLIClient.Profile]
    let isLoading: Bool

    var body: some View {
        if isLoading {
            ProgressView()
                .controlSize(.small)
        } else if profiles.isEmpty {
            Text(L10n.noDatabricksProfiles)
                .foregroundStyle(.secondary)
        } else {
            Picker("", selection: $selection) {
                ForEach(profiles) { profile in
                    Text(profile.name).tag(profile.name)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }
}
