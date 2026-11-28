import SwiftUI

/// The Agents section at the top of the Chat sidebar's `List`: one row per agent, with its last activity and what needs
/// the user. A row opens the agent's thread in the main area. With no agent, a card offers a blank one and the templates.
struct MainSidebarBotsSection: View {
    var coordinator: CodexChatCoordinator
    let agents: AgentsModel
    /// Whether the main area shows the chat, so an agent's row is the selected item while its thread is open.
    let isShowingChat: Bool
    let onOpen: (AgentRecord) -> Void

    @State private var isExpanded = true

    var body: some View {
        MeetingSidebarHeader(
            title: L10n.agentBots, isExpanded: isExpanded, onToggleExpansion: { isExpanded.toggle() },
            addButtonTitle: L10n.agentNew, onAdd: { agents.newAgent() },
            // Laid out as the Chat section: the count and chevron at the end, the add button in the count's place on hover.
            count: agents.summaries.count
        )
        .listRowSeparator(.hidden)
        // Agents work on their own, so the rows refresh while shown; a new thread or a turn ending reloads.
        .task(id: "\(isExpanded)-\(coordinator.isHistoryStale)") {
            while isExpanded, !Task.isCancelled {
                await agents.refresh()
                try? await Task.sleep(for: .seconds(15))
            }
        }

        if isExpanded {
            // A failed delete happens outside the editor card, which shows the other failures.
            if let error = agents.error, agents.draft == nil {
                Text(error)
                    .font(.dahliaSecondary)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .listRowSeparator(.hidden)
            }
            if agents.hasLoaded, agents.summaries.isEmpty {
                emptyCard
                    .listRowInsets(.vertical, 4)
                    .listRowSeparator(.hidden)
            }
            ForEach(agents.summaries) { summary in
                row(summary)
                    .listRowInsets(.vertical, 1.5)
                    .listRowSeparator(.hidden)
            }
        }
    }

    private func isSelected(_ agent: AgentRecord) -> Bool {
        isShowingChat && agent.threadID != nil && coordinator.dockedSession.backendThreadID == agent.threadID
    }

    private func row(_ summary: PiChatService.AgentSummary) -> some View {
        let agent = summary.agent
        let selected = isSelected(agent)
        return Button { onOpen(agent) } label: {
            HStack(spacing: 8) {
                AgentAvatarView(avatar: agent.avatar, color: agent.color, size: DahliaTypography.size(offset: 14))
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 8) {
                        Text(agent.name).lineLimit(1)
                        Spacer(minLength: 8)
                        if let updatedAt = summary.updatedAt {
                            Text(updatedAt, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                                .font(.dahliaSecondary)
                                .foregroundStyle(DahliaDesign.sidebarSecondaryTextColor)
                                .lineLimit(1)
                        }
                    }
                    let openItems = agents.openItems[agent.id, default: 0]
                    Text(openItems > 0
                        ? L10n.agentBotNeedsAttention(openItems)
                        : summary.preview?.nilIfBlank ?? L10n.agentBotIdle)
                        .font(.dahliaSecondary)
                        .foregroundStyle(openItems > 0 ? Color.accentColor : DahliaDesign.sidebarSecondaryTextColor)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            .contentShape(.rect)
            .modifier(SidebarNavigationRowModifier(isSelected: selected))
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(L10n.agentEdit, systemImage: "pencil") { agents.edit(agent) }
            Divider()
            Button(L10n.agentDelete, systemImage: "trash", role: .destructive) { agents.pendingDeletion = agent }
        }
    }

    /// As Orca's: the mascots and a title on one line, then making one from scratch or from a template.
    private var emptyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                HStack(spacing: -6) {
                    ForEach(["H1", "E1", "M1"], id: \.self) { mascot in
                        AgentAvatarView(avatar: AgentAvatar.mascot(mascot), color: AgentAvatar.defaultColor, size: 24)
                            .overlay {
                                RoundedRectangle(cornerRadius: AgentAvatarView.cornerRadius(24), style: .continuous)
                                    .strokeBorder(.background, lineWidth: 1.5)
                            }
                    }
                }
                Text(L10n.agentEmptyTitle).font(.dahliaHeadline).lineLimit(1)
            }
            HStack(spacing: 6) {
                // Built by hand so the icon takes the title's size and sits close to it, as Orca's "+ New bot" does.
                Button { agents.newAgent() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus").fontWeight(.semibold)
                        Text(L10n.agentCreate)
                    }
                }
                .buttonStyle(.dahlia(.primary))
                Menu(L10n.agentTemplates) {
                    ForEach(AgentTemplate.all) { template in
                        Button(template.name) { agents.newAgent(from: template) }
                    }
                }
                .menuStyle(.button)
                .buttonStyle(.dahlia(.secondary))
                .fixedSize()
            }
            // The base size less 2 pt, so the two fit the narrow sidebar as Orca's do.
            .font(.dahliaSecondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: .rect(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.separator) }
    }
}
