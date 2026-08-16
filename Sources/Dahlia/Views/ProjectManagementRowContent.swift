import SwiftUI

struct ProjectManagementRowContent: View {
    let node: ProjectTreeNode
    let isSelected: Bool

    @State private var isHovered = false

    var body: some View {
        Label {
            Text(node.displayName)
                .lineLimit(1)
                .truncationMode(.middle)
        } icon: {
            Image(systemName: folderSystemImage)
                .foregroundStyle(folderColor)
        }
        .badge(node.meetingCount)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .background(
            isHovered && !isSelected ? DahliaDesign.hoverHighlightColor : .clear,
            in: .rect(cornerRadius: 6)
        )
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var folderSystemImage: String {
        if node.project.parentProjectId == nil {
            "externaldrive"
        } else {
            "folder"
        }
    }

    private var folderColor: Color {
        if isSelected {
            .white
        } else {
            .secondary
        }
    }

    private var accessibilityLabel: String {
        "\(node.displayName), \(L10n.meetingCount(node.meetingCount))"
    }
}
