import SwiftUI

struct ProjectCatalogRow: View {
    let project: ProjectOverviewItem
    let appearance: ProjectAppearance
    let isPinned: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onTogglePin: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            Label {
                Text(project.projectName)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } icon: {
                ProjectAppearanceIcon(appearance: appearance)
            }
            .frame(maxWidth: 420, alignment: .leading)

            Text(activityDate, format: .relative(presentation: .numeric, unitsStyle: .wide))
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)

            HStack(spacing: 12) {
                Menu(L10n.projectOptions, systemImage: "ellipsis") {
                    Button(L10n.editProject, systemImage: "pencil", action: onEdit)
                    Button(L10n.deleteProject, systemImage: "trash", role: .destructive, action: onDelete)
                }
                .labelStyle(.iconOnly)
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()

                Button(isPinned ? L10n.unpinProject : L10n.pinProject, systemImage: isPinned ? "pin.fill" : "pin", action: onTogglePin)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .help(isPinned ? L10n.unpinProject : L10n.pinProject)

                Button(L10n.editProject, systemImage: "square.and.pencil", action: onEdit)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .help(L10n.editProject)
            }
            .foregroundStyle(.secondary)
            .frame(width: 88, alignment: .trailing)
            .opacity(isHovered ? 1 : 0.72)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 16)
        .contentShape(.rect)
        .background(isHovered ? Color.primary.opacity(0.04) : .clear)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .contain)
    }

    private var activityDate: Date {
        project.latestMeetingDate ?? project.createdAt
    }
}
