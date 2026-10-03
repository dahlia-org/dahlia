import SwiftUI

struct CodexChatEmptyStateView: View {
    let recentThreads: [CodexChatThreadSummary]
    let meetingNamesByID: [UUID: String]
    let showsProjectOrganizationShortcut: Bool
    let isProjectOrganizationShortcutEnabled: Bool
    let onOrganizeRecentMeetingsAndProjects: () -> Void
    let meetingReviewShortcutTitle: String?
    let isMeetingReviewShortcutEnabled: Bool
    let activityForThread: (String) -> CodexChatThreadActivity?
    let onReviewMeeting: () -> Void
    let onOpenThread: (CodexChatThreadSummary) -> Void
    let onShowAll: () -> Void

    @State private var hoveredPreset: Preset?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 40)

            VStack(alignment: .leading, spacing: 28) {
                if showsProjectOrganizationShortcut || meetingReviewShortcutTitle != nil {
                    presetSection
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

    private var presetSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.chatPresets)
                .font(.body)
                .foregroundStyle(DahliaDesign.optionalTextColor)

            VStack(alignment: .leading, spacing: 8) {
                if showsProjectOrganizationShortcut {
                    presetButton(
                        CodexChatProjectOrganizationShortcut.title,
                        preset: .projectOrganization,
                        isEnabled: isProjectOrganizationShortcutEnabled,
                        action: onOrganizeRecentMeetingsAndProjects
                    )
                }

                if let meetingReviewShortcutTitle {
                    presetButton(
                        meetingReviewShortcutTitle,
                        preset: .meetingReview,
                        isEnabled: isMeetingReviewShortcutEnabled,
                        action: onReviewMeeting
                    )
                }
            }
        }
    }

    private func presetButton(
        _ title: String,
        preset: Preset,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: "sparkles")
                .font(.body)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
        }
        .buttonStyle(.plain)
        .background(
            hoveredPreset == preset && isEnabled
                ? DahliaDesign.chipHoverColor
                : DahliaDesign.contentHighlightColor,
            in: Capsule()
        )
        .onHover { hovering in
            if hovering {
                hoveredPreset = preset
            } else if hoveredPreset == preset {
                hoveredPreset = nil
            }
        }
        .disabled(!isEnabled)
    }

    private var recentChatsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.recentChats)
                .font(.body)
                .foregroundStyle(DahliaDesign.optionalTextColor)

            VStack(spacing: 0) {
                ForEach(recentThreads) { thread in
                    Button {
                        onOpenThread(thread)
                    } label: {
                        CodexChatThreadRow(
                            thread: thread,
                            meetingNamesByID: meetingNamesByID,
                            activity: activityForThread(thread.id)
                        )
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(DahliaDesign.secondaryTextColor)
                }
            }

            Button(L10n.chatShowAll, action: onShowAll)
                .buttonStyle(.plain)
                .foregroundStyle(DahliaDesign.optionalTextColor)
                .padding(.top, 4)
        }
    }

    private enum Preset {
        case projectOrganization
        case meetingReview
    }
}
