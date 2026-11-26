import SwiftUI

struct CodexChatContextDivider: View {
    let context: CodexChatContext?

    var body: some View {
        CodexChatTimelineDivider(title: title, systemImage: "rectangle.3.group", accessibilityLabel: accessibilityLabel)
    }

    var title: String {
        guard let context else { return L10n.noMeetingSelected }
        let displayName = context.displayName.nilIfBlank ?? L10n.newMeeting
        return context.isDraft ? L10n.chatMeetingDraft(displayName) : displayName
    }

    var accessibilityLabel: String {
        L10n.chatContextChanged(title)
    }
}

/// A labeled rule across the conversation that marks where something changed.
struct CodexChatTimelineDivider: View {
    let title: String
    let systemImage: String
    var accessibilityLabel: String?

    var body: some View {
        HStack(spacing: CodexChatDesign.contextDividerSpacing) {
            rule
            Label(title, systemImage: systemImage)
                .lineLimit(1)
            rule
        }
        .font(.system(size: DahliaTypography.size(offset: -4)))
        .foregroundStyle(DahliaDesign.secondaryTextColor)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel ?? title)
    }

    private var rule: some View {
        Rectangle()
            .fill(.separator)
            .frame(maxWidth: .infinity)
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}
