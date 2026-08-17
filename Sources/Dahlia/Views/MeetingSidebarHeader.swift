import SwiftUI

struct MeetingSidebarHeader: View {
    @Binding var displayMode: MeetingSidebarDisplayMode
    let isExpanded: Bool
    let canCreateProject: Bool
    let onToggleExpansion: () -> Void
    let onCreateProject: () -> Void

    @State private var isHovered = false
    @FocusState private var isMenuFocused: Bool
    @FocusState private var isCreateProjectFocused: Bool

    var body: some View {
        HStack {
            Button(action: onToggleExpansion) {
                HStack(spacing: 5) {
                    Text(displayMode == .chronological ? L10n.meetings : L10n.project)
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .opacity(!isExpanded || isHovered ? 1 : 0)
                }
            }
            .buttonStyle(.plain)
            .font(DahliaDesign.sidebarFont)
            .accessibilityAddTraits(.isHeader)
            .accessibilityHint(isExpanded ? L10n.collapse : L10n.expand)

            Spacer()

            HStack(spacing: 8) {
                Menu {
                    Picker(L10n.sidebarOrganization, selection: $displayMode) {
                        Label(L10n.chronological, systemImage: "clock")
                            .tag(MeetingSidebarDisplayMode.chronological)
                        Label(L10n.groupByProject, systemImage: "folder")
                            .tag(MeetingSidebarDisplayMode.byProject)
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label(L10n.sidebarOrganization, systemImage: "ellipsis")
                        .labelStyle(.iconOnly)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .focused($isMenuFocused)
                .help(L10n.sidebarOrganization)

                if displayMode == .byProject {
                    Button(L10n.newProject, systemImage: "plus", action: onCreateProject)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .focused($isCreateProjectFocused)
                        .disabled(!canCreateProject)
                        .help(L10n.newProject)
                }
            }
            .opacity(isHovered || isMenuFocused || isCreateProjectFocused ? 1 : 0)
        }
        .contentShape(.rect)
        .onHover { isHovered = $0 }
        .foregroundStyle(.secondary)
        .padding(.vertical, DahliaDesign.sidebarRowVerticalPadding)
    }
}
