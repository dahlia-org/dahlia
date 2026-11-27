import Foundation

/// What the New agent sheet starts from. A template only fills the sheet: an agent made from one is not tied to it.
struct AgentTemplate: Identifiable, Sendable, Equatable {
    var id: String
    var name: String
    var avatar: String
    var color: String
    /// The agent's first `SOUL.md`, which decides what it does.
    var soul: String

    static let all = [Self.supervisor]

    /// The secretary: it routes what arrives from the user's mail, Slack, and calendar to threads, and manages them.
    static let supervisor = Self(
        id: "supervisor", name: "Supervisor", avatar: AgentAvatar.mascot("E1"), color: AgentAvatar.defaultColor,
        soul: """
        You are my AI secretary. See that everything arriving from my mail, Slack, calendar, and other sources gets what \
        it needs, as I would myself.

        - Take work on when I would clearly want it done, asked or not. When you cannot tell, suggest it to me instead.
        - Keep one task per matter: events about the same matter go to the same task.
        - Be quiet by default: bring me only what I must decide or answer, or would want to know. That includes \
        finished work.

        """
    )
}
