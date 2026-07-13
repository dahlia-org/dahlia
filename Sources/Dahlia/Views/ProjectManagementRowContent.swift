import SwiftUI

struct ProjectManagementRowContent: View {
    let node: ProjectTreeNode
    let isSelected: Bool

    var body: some View {
        Label {
            HStack(spacing: 6) {
                Text(node.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)

                Text("\(node.meetingCount)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(isSelected ? Color.white : Color(nsColor: .secondaryLabelColor))
                    .lineLimit(1)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .frame(minWidth: 18)
                    .background(meetingCountBackground, in: .capsule)
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityHidden(true)

                Spacer(minLength: 0)

                if node.project.missingOnDisk {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(isSelected ? .white : .orange)
                        .help(L10n.missingOnDisk)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
        } icon: {
            Image(systemName: node.project.missingOnDisk ? "folder.badge.questionmark" : "folder")
                .foregroundStyle(folderColor)
        }
    }

    private var meetingCountBackground: Color {
        isSelected ? Color.white.opacity(0.20) : Color(nsColor: .secondaryLabelColor).opacity(0.14)
    }

    private var folderColor: Color {
        if node.project.missingOnDisk {
            .orange
        } else if isSelected {
            .white
        } else {
            .secondary
        }
    }

    private var accessibilityLabel: String {
        var label = "\(node.displayName), \(L10n.meetingCount(node.meetingCount))"
        if node.project.missingOnDisk {
            label += ", \(L10n.missingOnDisk)"
        }
        return label
    }
}
