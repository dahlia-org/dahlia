import SwiftUI

struct CodexChatAddPanel: View {
    let showsMeetingPicker: Bool
    let meetingReferences: [CodexChatMeetingReference]
    let highlightedMeetingID: UUID?
    let mcpSettings: AgentMCPSettings
    let onAttachImages: () -> Void
    let onAddMeetingReference: () -> Void
    let onSelectMeeting: (CodexChatMeetingReference) -> Void
    let onOpenMCPSettings: () -> Void

    @State private var showsMCPServers = false

    var body: some View {
        Group {
            if showsMeetingPicker {
                CodexChatMeetingPicker(
                    references: meetingReferences,
                    highlightedID: highlightedMeetingID,
                    onSelect: onSelectMeeting
                )
            } else if showsMCPServers {
                CodexChatMCPServersView(
                    settings: mcpSettings,
                    onBack: { showsMCPServers = false },
                    onOpenSettings: onOpenMCPSettings
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
                    CodexChatConfigurationRow(
                        title: L10n.chatMCPServers,
                        isSelected: false,
                        leadingSystemImage: "point.3.connected.trianglepath.dotted",
                        trailingSystemImage: "chevron.right",
                        action: { showsMCPServers = true }
                    )
                }
                .padding(10)
            }
        }
        .frame(maxWidth: .infinity)
        .codexChatPanelStyle()
    }
}
