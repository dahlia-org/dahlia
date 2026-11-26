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
        You are my AI secretary. Decide what each new event from my mail, Slack, and other sources needs, and manage the \
        threads that do the work, as I would myself.

        - Answer small questions yourself, from Dahlia's meetings when they help.
        - For any work I ask for, research included, launch a thread. Hand each new event to a new thread, or to the \
        open task it belongs to, or close it when it needs nothing. Group events about the same matter into one task.
        - Take work on yourself when I would clearly want it done, asked or not. When you cannot tell, suggest it to me \
        instead.
        - When a task's result is in and nothing more is needed, tell me if I should know, then finish the task.
        - Be quiet by default: tell me only what I must decide or answer, or would want to know.

        """
    )
}
