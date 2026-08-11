import SwiftUI

struct OrganizationDeletionSection: View {
    let onRequestDeletion: () -> Void

    var body: some View {
        Section {
            Button(
                L10n.deleteOrganizationAction,
                systemImage: "trash",
                role: .destructive,
                action: onRequestDeletion
            )
        } header: {
            Text(L10n.dangerZone)
        } footer: {
            Text(L10n.deleteOrganizationHelp)
        }
    }
}
