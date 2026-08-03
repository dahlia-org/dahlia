import SwiftUI

struct CodexChatEmptyStateView: View {
    let recentThreads: [CodexChatThreadSummary]
    let meetingNamesByID: [UUID: String]
    let showsProjectOrganizationShortcut: Bool
    let isProjectOrganizationShortcutEnabled: Bool
    let onOrganizeRecentMeetingsAndProjects: () -> Void
    let onOpenThread: (CodexChatThreadSummary) -> Void
    let onShowAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsProjectOrganizationShortcut {
                Button(action: onOrganizeRecentMeetingsAndProjects) {
                    Label(CodexChatProjectOrganizationShortcut.title, systemImage: "sparkles")
                        .font(.callout)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                        .frame(minHeight: 28)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(!isProjectOrganizationShortcutEnabled)
                .padding(.top, 12)
            }

            Spacer(minLength: 40)

            if !recentThreads.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.recentChats)
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)

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
                        .foregroundStyle(.secondary)
                    }

                    Button(L10n.chatShowAll, action: onShowAll)
                        .buttonStyle(.plain)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 4)
                }
            }
        }
        .padding(.horizontal, CodexChatDesign.contentHorizontalPadding)
        .padding(.bottom, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
