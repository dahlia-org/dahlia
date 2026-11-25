import Foundation

enum PiExecutionProfile: String, Sendable {
    /// `intake` reads one always-on Source and records what it read; it cannot write anything else. `router` reads
    /// nothing outside its prompt and only routes events and makes Items. `worker` reads its Task's sources and reports.
    case interactive, scheduled, review, intake, router, worker

    static let routerTools = ["task_create", "task_suggest", "task_assign", "event_close", "task_finish", "item_create"]
    static let workerTools = ["task_report", "task_return", "task_wait"]
    /// The secretary's Home thread is an interactive chat with this one more tool.
    static let homeTools = ["secretary_request"]

    var fileTools: [String] {
        switch self {
        case .interactive: ["read", "ls", "write", "edit", "bash"]
        case .scheduled: ["read", "ls"]
        case .review, .intake, .router, .worker: []
        }
    }

    func allows(_ tool: String, readOnly: Bool = false) -> Bool {
        switch self {
        case .interactive: true
        case .scheduled: ["read", "ls", "skills_list", "skill_view"].contains(tool) || (tool.hasPrefix("mcp__") && readOnly)
        case .review: ["memory", "skills_list", "skill_view", "skill_manage"].contains(tool)
        case .intake: tool == "event_record" || (tool.hasPrefix("mcp__") && !tool.hasPrefix("mcp__dahlia__") && readOnly)
        case .router: Self.routerTools.contains(tool)
        case .worker: Self.workerTools.contains(tool) || (tool.hasPrefix("mcp__") && readOnly)
        }
    }
}
