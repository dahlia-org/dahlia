import SwiftUI

struct ProjectManagementRowContent: View {
    let node: ProjectTreeNode
    let isSelected: Bool
    let appearance: ProjectAppearance

    var body: some View {
        Label {
            Text(node.displayName)
                .lineLimit(1)
                .truncationMode(.middle)
        } icon: {
            ProjectAppearanceIcon(appearance: appearance)
        }
        .badge(node.meetingCount)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .modifier(SidebarNavigationRowModifier(isSelected: isSelected))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        "\(node.displayName), \(L10n.meetingCount(node.meetingCount))"
    }
}
