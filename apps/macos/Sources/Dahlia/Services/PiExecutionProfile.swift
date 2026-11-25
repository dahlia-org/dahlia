import Foundation

enum PiExecutionProfile: String, Sendable {
    /// `intake` reads one always-on Source and records what it read; it cannot write anything else. `bot` is Super Agent's
    /// thread (and the tasks it delegates): it talks with the user and routes events, reads Dahlia's meetings and its home,
    /// and hands work to ordinary threads with the thread tools.
    case interactive, scheduled, review, intake, bot

    static let botTools = ["inbox_read", "event_close", "item_create", "task_finish", "soul_write"]

    var fileTools: [String] {
        switch self {
        case .interactive: ["read", "ls", "write", "edit", "bash"]
        case .scheduled: ["read", "ls"]
        // Seatbelt keeps its writes in its home.
        case .bot: ["read", "ls", "write", "edit"]
        case .review, .intake: []
        }
    }

    func allows(_ tool: String, readOnly: Bool = false) -> Bool {
        switch self {
        case .interactive: true
        case .scheduled: ["read", "ls", "skills_list", "skill_view"].contains(tool) || (tool.hasPrefix("mcp__") && readOnly)
        case .review: ["memory", "skills_list", "skill_view", "skill_manage"].contains(tool)
        case .intake: tool == "event_record" || (tool.hasPrefix("mcp__") && !tool.hasPrefix("mcp__dahlia__") && readOnly)
        case .bot: Self.botTools.contains(tool) || fileTools.contains(tool)
            || (PiChatService.readThreadTools + PiChatService.manageThreadTools).contains(tool) || (tool.hasPrefix("mcp__dahlia__") && readOnly)
        }
    }
}
