import SwiftUI

struct CodexChatContextDivider: View {
    let context: CodexChatContext?

    var body: some View {
        HStack(spacing: CodexChatDesign.contextDividerSpacing) {
            Rectangle()
                .fill(.separator)
                .frame(maxWidth: .infinity)
                .frame(height: 1)
                .accessibilityHidden(true)

            Label(title, systemImage: "rectangle.3.group")
                .lineLimit(1)
                .padding(.horizontal, CodexChatDesign.contextLabelHorizontalPadding)
                .padding(.vertical, CodexChatDesign.contextLabelVerticalPadding)
                .background {
                    RoundedRectangle(cornerRadius: CodexChatDesign.contextLabelCornerRadius)
                        .fill(.background)
                        .stroke(.separator, lineWidth: 1)
                }

            Rectangle()
                .fill(.separator)
                .frame(maxWidth: .infinity)
                .frame(height: 1)
                .accessibilityHidden(true)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    var title: String {
        guard let context else { return L10n.noMeetingSelected }
        let meetingName = context.meetingName.nilIfBlank ?? L10n.newMeeting
        return context.isDraft ? L10n.chatMeetingDraft(meetingName) : meetingName
    }

    var accessibilityLabel: String {
        L10n.chatContextChanged(title)
    }
}
