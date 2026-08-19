import SwiftUI

struct ProjectSidebarHoverCard: View {
    let project: ProjectOverviewItem
    let appearance: ProjectAppearance
    let isPinned: Bool
    let onTogglePin: () -> Void
    let onEdit: () -> Void

    @State private var isPinHovered = false
    @State private var isEditHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProjectAppearanceIcon(appearance: appearance)

                Text(project.projectName)
                    .bold()
                    .lineLimit(2)

                Spacer(minLength: 0)

                Button(pinActionLabel, systemImage: pinSystemImage, action: onTogglePin)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.black.opacity(0.55))
                    .padding(5)
                    .background(
                        isPinHovered ? Color.black.opacity(0.08) : .clear,
                        in: .rect(corners: .concentric(
                            minimum: .fixed(DahliaDesign.Highlight.compactCornerRadius)
                        ))
                    )
                    .contentShape(.rect(corners: .concentric(
                        minimum: .fixed(DahliaDesign.Highlight.compactCornerRadius)
                    )))
                    .onHover { isPinHovered = $0 }
            }

            Label(meetingCountText, systemImage: "calendar")

            Divider()

            Button(L10n.editProject, systemImage: "gearshape", action: onEdit)
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(
                    isEditHovered ? Color.black.opacity(0.08) : .clear,
                    in: .rect(corners: .concentric(
                        minimum: .fixed(DahliaDesign.Highlight.compactCornerRadius)
                    ))
                )
                .contentShape(.rect(corners: .concentric(
                    minimum: .fixed(DahliaDesign.Highlight.compactCornerRadius)
                )))
                .onHover { isEditHovered = $0 }
        }
        .dahliaSidebarHoverCard()
    }

    var meetingCountText: String {
        L10n.meetingCount(project.meetingCount)
    }

    var pinActionLabel: String {
        isPinned ? L10n.unpinProject : L10n.pinProject
    }

    var pinSystemImage: String {
        isPinned ? "pin.fill" : "pin"
    }
}
