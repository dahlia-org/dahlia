import SwiftUI

struct CodexChatEmptyStateView: View {
    let hasRecentThreads: Bool
    let showsProjectOrganizationShortcut: Bool
    let isProjectOrganizationShortcutEnabled: Bool
    let onOrganizeRecentMeetingsAndProjects: () -> Void
    let meetingReviewShortcutTitle: String?
    let isMeetingReviewShortcutEnabled: Bool
    let onReviewMeeting: () -> Void
    let onShowAll: () -> Void

    @State private var hoveredPreset: Preset?
    @State private var hoveredHistory = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if showsProjectOrganizationShortcut || meetingReviewShortcutTitle != nil {
                    presetSection
                }

                if hasRecentThreads {
                    Button(action: onShowAll) {
                        Label(L10n.recentChats, systemImage: "clock.arrow.circlepath")
                            .font(.dahliaBody)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(DahliaDesign.secondaryTextColor)
                    .background(hoveredHistory ? DahliaDesign.contentHighlightColor : .clear, in: .rect(cornerRadius: 8))
                    .onHover { hoveredHistory = $0 }
                }
            }
            .padding(.horizontal, CodexChatDesign.contentHorizontalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private var presetSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), alignment: .leading)], alignment: .leading, spacing: 8) {
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
                .font(.dahliaBody)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .background(
            hoveredPreset == preset && isEnabled
                ? DahliaDesign.chipHoverColor
                : DahliaDesign.contentHighlightColor,
            in: .rect(cornerRadius: 8)
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

    private enum Preset {
        case projectOrganization
        case meetingReview
    }
}
