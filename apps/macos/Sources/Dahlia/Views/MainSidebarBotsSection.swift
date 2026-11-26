import SwiftUI

/// The Bots section at the top of the Chat sidebar's `List`: Dahlia Bot's one row, with its last activity and what needs
/// the user. The row opens the bot's thread in the main area.
struct MainSidebarBotsSection: View {
    var coordinator: CodexChatCoordinator
    /// Whether the main area shows the chat, so the bot's row is the selected item while its thread is open.
    let isShowingChat: Bool
    let onOpen: () -> Void

    @AppStorage private var botThreadID: String?
    @State private var isExpanded = true
    @State private var summary = PiChatService.BotSummary()

    init(coordinator: CodexChatCoordinator, isShowingChat: Bool, onOpen: @escaping () -> Void) {
        self.coordinator = coordinator
        self.isShowingChat = isShowingChat
        self.onOpen = onOpen
        _botThreadID = AppStorage(AgentBotSettings.botThreadKey(for: AppAccount.key))
    }

    private var isSelected: Bool {
        isShowingChat && botThreadID != nil && coordinator.dockedSession.backendThreadID == botThreadID
    }

    var body: some View {
        MeetingSidebarHeader(title: L10n.agentBots, isExpanded: isExpanded, onToggleExpansion: { isExpanded.toggle() })
            .listRowSeparator(.hidden)
            // The bot works on its own, so the row refreshes while it is shown; a new thread or a turn ending reloads.
            .task(id: "\(isExpanded)-\(botThreadID ?? "")-\(coordinator.isHistoryStale)") {
                while isExpanded, !Task.isCancelled {
                    if let loaded = try? await PiChatService.shared.botSummary(), !Task.isCancelled { summary = loaded }
                    try? await Task.sleep(for: .seconds(15))
                }
            }

        if isExpanded {
            Button(action: onOpen) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .dahliaFixedSymbol()
                        .foregroundStyle(.white)
                        .frame(width: DahliaTypography.size(offset: 10), height: DahliaTypography.size(offset: 10))
                        .background(Color.accentColor, in: .circle)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 8) {
                            Text(L10n.agentBotName).lineLimit(1)
                            Spacer(minLength: 8)
                            if let updatedAt = summary.updatedAt {
                                Text(updatedAt, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                                    .font(.dahliaSecondary)
                                    .foregroundStyle(DahliaDesign.sidebarSecondaryTextColor)
                                    .lineLimit(1)
                            }
                        }
                        Text(summary.openItems > 0
                            ? L10n.agentBotNeedsAttention(summary.openItems)
                            : summary.preview?.nilIfBlank ?? L10n.agentBotIdle)
                            .font(.dahliaSecondary)
                            .foregroundStyle(summary.openItems > 0 ? Color.accentColor : DahliaDesign.sidebarSecondaryTextColor)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                .contentShape(.rect)
                .modifier(SidebarNavigationRowModifier(isSelected: isSelected))
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
            .buttonStyle(.plain)
            .listRowInsets(.vertical, 1.5)
            .listRowSeparator(.hidden)
        }
    }
}
