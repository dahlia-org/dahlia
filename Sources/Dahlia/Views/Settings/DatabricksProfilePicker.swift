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
                .foregroundStyle(DahliaDesign.secondaryTextColor)
        } else {
            DahliaMenuPicker(
                title: L10n.databricksProfile,
                selection: $selection,
                options: profiles.map(\.name),
                label: { $0 }
            )
            .labelsHidden()
        }
    }
}
