import SwiftUI

struct CodexChatAddPanel: View {
    let windowBounds: CGRect
    let showsMeetingPicker: Bool
    let showsConnectors: Bool
    let meetingReferences: [CodexChatMeetingReference]
    let highlightedMeetingID: UUID?
    let mcpSettings: AgentMCPSettings
    let onAttachImages: () -> Void
    let onAddMeetingReference: () -> Void
    let onSelectMeeting: (CodexChatMeetingReference) -> Void
    let onOpenMCPSettings: () -> Void

    @State private var showsMCPServers = false

    var body: some View {
        HStack(alignment: .bottom, spacing: CodexChatAddPanelLayout.submenuSpacing) {
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
                        if showsConnectors {
                            CodexChatConfigurationRow(
                                title: L10n.agentMCPs,
                                isSelected: showsMCPServers,
                                leadingSystemImage: "point.3.connected.trianglepath.dotted",
                                trailingSystemImage: "chevron.right",
                                action: { showsMCPServers.toggle() }
                            )
                        }
                    }
                    .padding(10)
                }
            }
            .frame(width: panelWidth)
            .frame(maxHeight: CodexChatAddPanelLayout.maximumHeight(windowBounds: windowBounds))
            .fixedSize(horizontal: false, vertical: true)
            .codexChatPanelStyle()

            if showsConnectors, showsMCPServers, !showsMeetingPicker {
                CodexChatMCPServersView(settings: mcpSettings, onOpenSettings: onOpenMCPSettings)
                    .frame(width: panelWidth)
                    .frame(maxHeight: CodexChatAddPanelLayout.maximumHeight(windowBounds: windowBounds))
                    .fixedSize(horizontal: false, vertical: true)
                    .codexChatPanelStyle()
            }
        }
    }

    private var panelWidth: CGFloat {
        CodexChatAddPanelLayout.width(windowBounds: windowBounds, showsSubmenu: showsConnectors && showsMCPServers && !showsMeetingPicker)
    }
}
