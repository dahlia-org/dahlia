import SwiftUI

struct ProjectManagementRowContent: View {
    let node: ProjectTreeNode
    let isSelected: Bool

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
