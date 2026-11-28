import SwiftUI

/// The steps of a finished run before its final answer: reasoning, tools, and steered input.
struct CodexChatWorkLogView: View {
    let steps: [CodexChatMessage]
    let duration: TimeInterval?
    /// The agent whose chat this is; its avatar leads the header.
    var agent: AgentRecord?
    let meetingNamesByID: [UUID: String]
    let meetingReferencesByID: [UUID: CodexChatMeetingReference]

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                if steps.isEmpty {
                    CodexChatRunHeaderLabel(agent: agent, title: L10n.chatWorkedFor(duration))
                } else {
                    Button { isExpanded.toggle() } label: {
                        CodexChatRunHeaderLabel(
                            agent: agent,
                            title: L10n.chatWorkedFor(duration),
                            chevron: isExpanded ? "chevron.down" : "chevron.right"
                        )
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .pointerStyle(.link)
                    .accessibilityHint(isExpanded ? L10n.collapse : L10n.expand)
                }

                Divider()
            }

            if isExpanded, !steps.isEmpty {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(steps) { step in
                        CodexChatMessageRow(
                            message: step,
                            showsFooter: false,
                            meetingNamesByID: meetingNamesByID,
                            meetingReferencesByID: meetingReferencesByID
                        )
                    }
                }
            }
        }
    }
}

/// The header of a run still streaming: the agent's avatar and the time since the run started.
struct CodexChatRunningHeaderView: View {
    let startedAt: Date?
    let agent: AgentRecord?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let startedAt {
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    CodexChatRunHeaderLabel(
                        agent: agent,
                        title: L10n.chatWorkingFor(context.date.timeIntervalSince(startedAt))
                    )
                }
            } else {
                CodexChatRunHeaderLabel(agent: agent, title: L10n.chatThinking)
            }
            Divider()
        }
    }
}

struct CodexChatRunHeaderLabel: View {
    let agent: AgentRecord?
    let title: String
    var chevron: String?

    var body: some View {
        HStack(spacing: 8) {
            if let agent {
                AgentAvatarView(avatar: agent.avatar, color: agent.color, size: DahliaTypography.size(offset: 10))
            }
            HStack(spacing: 4) {
                Text(title).monospacedDigit()
                if let chevron { Image(systemName: chevron).accessibilityHidden(true) }
            }
        }
        .font(.dahliaSecondary)
        .foregroundStyle(DahliaDesign.secondaryTextColor)
        .padding(.vertical, 2)
    }
}
