import SwiftUI

struct CodexChatToolUsesView: View {
    let activities: [CodexChatToolActivity]
    @State private var isExpanded = false

    var body: some View {
        Group {
            if activities.count == 1, let activity = activities.first {
                row(activity)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Button { isExpanded.toggle() } label: {
                        HStack(spacing: 8) {
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                .accessibilityHidden(true)
                            Label(L10n.chatToolUseCount(activities.count), systemImage: "hammer")
                        }
                        .padding(.vertical, 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .pointerStyle(.link)
                    .accessibilityHint(isExpanded ? L10n.collapse : L10n.expand)

                    if isExpanded {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(activities.indices, id: \.self) { index in
                                row(activities[index])
                            }
                        }
                        .padding(.leading, 20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .font(.dahliaSecondary)
        .foregroundStyle(DahliaDesign.secondaryTextColor)
    }

    private func row(_ activity: CodexChatToolActivity) -> some View {
        HStack(spacing: 8) {
            Image(systemName: activity.toolSymbol)
                .frame(width: 16)
                .accessibilityHidden(true)
            Text([activity.name, activity.detail].compactMap(\.self).joined(separator: " "))
                .lineLimit(1)
                .help(activity.detail ?? activity.name)
            if activity.status == .failed || activity.status == .inaccessible {
                Image(systemName: activity.symbol)
                    .foregroundStyle(.orange)
                    .accessibilityLabel(activity.text)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
