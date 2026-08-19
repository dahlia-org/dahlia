import SwiftUI

struct MainSidebarProjectNavigationRow: View {
    @Binding var displayMode: MeetingSidebarDisplayMode
    let isSelected: Bool
    let canCreateProject: Bool
    let onOpen: () -> Void
    let onCreateProject: () -> Void

    @State private var isHovered = false
    @FocusState private var isMenuFocused: Bool
    @FocusState private var isCreateProjectFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onOpen) {
                Label(L10n.projects, systemImage: "folder")
                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            HStack(spacing: 8) {
                MeetingSidebarOrganizationMenu(displayMode: $displayMode)
                    .focused($isMenuFocused)

                Button(L10n.newProject, systemImage: "plus", action: onCreateProject)
                    .labelStyle(.iconOnly)
                    .dahliaFixedSymbol()
                    .buttonStyle(.plain)
                    .focused($isCreateProjectFocused)
                    .disabled(!canCreateProject)
                    .help(L10n.newProject)
            }
            .opacity(isHovered || isMenuFocused || isCreateProjectFocused ? 1 : 0)
        }
        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
        .contentShape(.rect)
        .modifier(SidebarNavigationRowModifier(isSelected: isSelected))
        .onHover { isHovered = $0 }
    }
}
