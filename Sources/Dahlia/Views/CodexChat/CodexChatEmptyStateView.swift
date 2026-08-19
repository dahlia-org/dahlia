import SwiftUI

struct CodexChatEmptyStateView: View {
    let recentThreads: [CodexChatThreadSummary]
    let meetingNamesByID: [UUID: String]
    let showsProjectOrganizationShortcut: Bool
    let isProjectOrganizationShortcutEnabled: Bool
    let onOrganizeRecentMeetingsAndProjects: () -> Void
    let onOpenThread: (CodexChatThreadSummary) -> Void
    let onShowAll: () -> Void

    @State private var isPresetHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 40)

            VStack(alignment: .leading, spacing: 28) {
                if showsProjectOrganizationShortcut {
                    projectOrganizationPresetSection
                }

                if !recentThreads.isEmpty {
                    recentChatsSection
                }
            }
        }
        .padding(.horizontal, CodexChatDesign.contentHorizontalPadding)
        .padding(.bottom, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var projectOrganizationPresetSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.chatPresets)
                .font(.body)
                .foregroundStyle(DahliaDesign.optionalTextColor)

            Button(action: onOrganizeRecentMeetingsAndProjects) {
                Label(CodexChatProjectOrganizationShortcut.title, systemImage: "sparkles")
                    .font(.body)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
            }
            .buttonStyle(.plain)
            .background(
                isPresetHovered && isProjectOrganizationShortcutEnabled
                    ? DahliaDesign.chipHoverColor
                    : DahliaDesign.contentHighlightColor,
                in: Capsule()
            )
            .onHover { isPresetHovered = $0 }
            .disabled(!isProjectOrganizationShortcutEnabled)
        }
    }

    private var recentChatsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.recentChats)
                .font(.body)
                .foregroundStyle(DahliaDesign.optionalTextColor)

            ForEach(recentThreads) { thread in
                Button {
                    onOpenThread(thread)
                } label: {
                    CodexChatThreadRow(
                        thread: thread,
                        meetingNamesByID: meetingNamesByID
                    )
                }
                .buttonStyle(.plain)
                .foregroundStyle(DahliaDesign.secondaryTextColor)
            }

            Button(L10n.chatShowAll, action: onShowAll)
                .buttonStyle(.plain)
                .foregroundStyle(DahliaDesign.optionalTextColor)
                .padding(.top, 4)
        }
    }
}
