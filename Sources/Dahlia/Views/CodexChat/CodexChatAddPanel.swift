import SwiftUI

struct CodexChatAddPanel: View {
    let showsMeetingPicker: Bool
    let meetingReferences: [CodexChatMeetingReference]
    let highlightedMeetingID: UUID?
    let onAttachImages: () -> Void
    let onAddMeetingReference: () -> Void
    let onSelectMeeting: (CodexChatMeetingReference) -> Void

    var body: some View {
        Group {
            if showsMeetingPicker {
                CodexChatMeetingPicker(
                    references: meetingReferences,
                    highlightedID: highlightedMeetingID,
                    onSelect: onSelectMeeting
                )
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    CodexChatConfigurationRow(
                        title: L10n.attachChatImages,
                        isSelected: false,
                        leadingSystemImage: "photo",
                        action: onAttachImages
                    )
                    CodexChatConfigurationRow(
                        title: L10n.addMeetingReference,
                        isSelected: false,
                        leadingSystemImage: "text.document",
                        action: onAddMeetingReference
                    )
                }
                .padding(10)
                .frame(width: CodexChatDesign.addPanelWidth)
            }
        }
        .codexChatPanelStyle()
    }
}
