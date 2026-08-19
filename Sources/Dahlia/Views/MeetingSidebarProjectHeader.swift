import SwiftUI

struct MeetingSidebarProjectHeader: View {
    let project: ProjectOverviewItem
    let appearance: ProjectAppearance
    let isPinned: Bool
    let isExpanded: Bool
    let isSelected: Bool
    let canCreateMeeting: Bool
    let onToggleExpansion: () -> Void
    let onOpen: (ProjectNavigationIntent) -> Void
    let onTogglePin: () -> Void
    let onCreateMeeting: () -> Void

    @Environment(MeetingSidebarHoverController.self) private var hoverController
    @State private var isHovered = false
    @State private var isOptionsHovered = false
    @State private var isCreateMeetingHovered = false
    @State private var rowFrame: CGRect = .zero
    @FocusState private var isMenuFocused: Bool
    @FocusState private var isCreateMeetingFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onToggleExpansion) {
                Label {
                    Text(project.projectName)
                } icon: {
                    ProjectAppearanceIcon(appearance: appearance)
                }
                .font(.callout)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .foregroundStyle(DahliaDesign.sidebarPrimaryTextColor)
            .layoutPriority(1)
            .accessibilityLabel(project.projectName)
            .accessibilityHint(isExpanded ? L10n.collapse : L10n.expand)

            HStack(spacing: 6) {
                Menu {
                    Button(
                        isPinned ? L10n.unpinProject : L10n.pinProject,
                        systemImage: isPinned ? "pin.slash" : "pin",
                        action: onTogglePin
                    )
                    Button(L10n.editProject, systemImage: "gearshape", action: { onOpen(.edit) })
                    Button(L10n.deleteProject, systemImage: "trash", role: .destructive, action: { onOpen(.delete) })
                } label: {
                    Label(L10n.projectOptions, systemImage: "ellipsis")
                        .labelStyle(.iconOnly)
                        .dahliaFixedSymbol()
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .focused($isMenuFocused)
                .foregroundStyle(isOptionsHovered ? DahliaDesign.sidebarPrimaryTextColor : DahliaDesign.sidebarSecondaryTextColor)
                .onHover { isOptionsHovered = $0 }
                .help(L10n.projectOptions)

                Button(L10n.createNewMeeting, systemImage: "plus", action: onCreateMeeting)
                    .labelStyle(.iconOnly)
                    .dahliaFixedSymbol()
                    .buttonStyle(.plain)
                    .fixedSize()
                    .focused($isCreateMeetingFocused)
                    .foregroundStyle(isCreateMeetingHovered ? DahliaDesign.sidebarPrimaryTextColor : DahliaDesign.sidebarSecondaryTextColor)
                    .disabled(!canCreateMeeting)
                    .help(L10n.createNewMeeting)
                    .onHover { isCreateMeetingHovered = $0 }
            }
            .opacity(isHovered || isMenuFocused || isCreateMeetingFocused ? 1 : 0)
        }
        .padding(.vertical, DahliaDesign.sidebarRowVerticalPadding)
        .padding(.trailing, 8)
        .dahliaSidebarHoverHighlight(
            isHovered: isHovered,
            isSelected: isSelected,
            verticalOutset: DahliaDesign.projectSidebarRowHighlightVerticalOutset
        )
        .contentShape(.rect)
        .onGeometryChange(for: CGRect.self) { geometry in
            geometry.frame(in: .global)
        } action: { frame in
            rowFrame = frame
            hoverController.updateProjectRowFrame(frame, for: project.projectId)
        }
        .onHover(perform: updateHoverState)
        .onDisappear { hoverController.projectDisappeared(for: project.projectId) }
    }

    private func updateHoverState(_ isHovered: Bool) {
        self.isHovered = isHovered
        if isHovered {
            hoverController.projectHoverBegan(
                project: project,
                appearance: appearance,
                isPinned: isPinned,
                rowFrame: rowFrame
            )
        } else {
            hoverController.projectRowHoverEnded(for: project.projectId)
        }
    }
}
