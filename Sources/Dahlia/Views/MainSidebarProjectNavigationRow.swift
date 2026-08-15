import SwiftUI

struct MainSidebarProjectNavigationRow: View {
    let isSelected: Bool
    let canCreateProject: Bool
    let onShowProjectManagement: () -> Void
    let onCreateProject: () -> Void

    @State private var isCreateProjectButtonHovered = false

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

            Button(L10n.newProject, systemImage: "plus.circle", action: onCreateProject)
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(createProjectButtonColor)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
                .disabled(!canCreateProject)
                .help(L10n.newProject)
                .onHover { isCreateProjectButtonHovered = $0 }
        }
        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
        .modifier(SidebarNavigationRowModifier(isSelected: isSelected))
    }

    private var createProjectButtonColor: Color {
        guard canCreateProject else { return .secondary.opacity(0.35) }
        return isCreateProjectButtonHovered ? .primary : .secondary.opacity(0.65)
    }
}
