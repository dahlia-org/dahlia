import SwiftUI

struct MainSidebarProjectNavigationRow: View {
    let isSelected: Bool
    let canCreateProject: Bool
    let onShowProjectManagement: () -> Void
    let onCreateProject: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onShowProjectManagement) {
                Label(L10n.projectManagement, systemImage: "folder")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.manageProjects)
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            MainSidebarNavigationAccessoryButton(
                title: L10n.newProject,
                systemImage: "plus.circle",
                isEnabled: canCreateProject,
                action: onCreateProject
            )
        }
        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
        .modifier(SidebarNavigationRowModifier(isSelected: isSelected))
    }
}
