import SwiftUI

struct CodexChatSlashCommandPicker: View {
    let commands: [CodexChatSlashCommand]
    let highlightedID: String?
    let isLoading: Bool
    let errorMessage: String?
    let maximumHeight: CGFloat
    let onSelect: (CodexChatSlashCommand) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.chatSlashCommands)
                .font(.dahliaSectionHeader)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
            if isLoading {
                ProgressView().controlSize(.small).padding(10)
            } else if let errorMessage {
                Text(errorMessage).font(.dahliaSecondary).padding(10)
            } else if commands.isEmpty {
                Text(L10n.chatNoMatchingCommands).font(.dahliaSecondary).padding(10)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(commands) { command in
                                CodexChatConfigurationRow(
                                    title: "/" + command.name,
                                    isSelected: command.id == highlightedID,
                                    leadingSystemImage: command.source == "skill" ? "sparkles" : "slash.circle",
                                    action: { onSelect(command) }
                                )
                                .help(command.description ?? command.name)
                                .accessibilityHint(command.description ?? "")
                                .id(command.id)
                                .accessibilityIdentifier("chat-slash-command-" + command.name)
                            }
                        }
                    }
                    .onChange(of: highlightedID) {
                        if let highlightedID { proxy.scrollTo(highlightedID, anchor: .center) }
                    }
                }
                .frame(height: max(0, min(maximumHeight - 38, CGFloat(min(commands.count, 6)) * (CodexChatDesign.configurationRowHeight + 2))))
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .codexChatPanelStyle()
        .accessibilityLabel(L10n.chatSlashCommands)
        .accessibilityIdentifier("chat-slash-commands")
    }
}
