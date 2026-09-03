import SwiftUI

struct ProjectCatalogRow: View {
    let project: ProjectOverviewItem
    let appearance: ProjectAppearance
    let isPinned: Bool
    let canEdit: Bool
    let canCreateMeeting: Bool
    let onOpen: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onTogglePin: () -> Void
    let onCreateMeeting: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    Label {
                        Text(project.projectName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } icon: {
                        ProjectAppearanceIcon(appearance: appearance)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Text(activityDate, format: .relative(presentation: .numeric, unitsStyle: .wide))
                        .foregroundStyle(.secondary)
                        .frame(width: 120, alignment: .leading)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            HStack(spacing: 4) {
                if canEdit {
                    Menu(L10n.projectOptions, systemImage: "ellipsis") {
                        Button(L10n.editProject, systemImage: "pencil", action: onEdit)
                        Button(L10n.deleteProject, systemImage: "trash", role: .destructive, action: onDelete)
                    }
                    .labelStyle(.iconOnly)
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .projectCatalogIconHoverHighlight()
                }

                Button(isPinned ? L10n.unpinProject : L10n.pinProject, systemImage: isPinned ? "pin.fill" : "pin", action: onTogglePin)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .help(isPinned ? L10n.unpinProject : L10n.pinProject)
                    .projectCatalogIconHoverHighlight()

                Button(L10n.createNewMeeting, systemImage: "square.and.pencil", action: onCreateMeeting)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .disabled(!canCreateMeeting)
                    .help(L10n.createNewMeeting)
                    .projectCatalogIconHoverHighlight()
            }
            .foregroundStyle(.secondary)
            .frame(width: 80, alignment: .trailing)
            .opacity(isHovered ? 1 : 0.72)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 16)
        .contentShape(.rect)
        .background(isHovered ? DahliaDesign.contentHighlightColor : .clear)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .contain)
    }

    private var activityDate: Date {
        project.latestMeetingDate ?? project.createdAt
    }
}
