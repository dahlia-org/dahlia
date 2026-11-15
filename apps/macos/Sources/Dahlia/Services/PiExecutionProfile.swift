import Foundation

enum PiExecutionProfile: String, Sendable {
    case interactive, scheduled, review

    var fileTools: [String] {
        switch self {
        case .interactive: ["read", "ls", "write", "edit", "bash"]
        case .scheduled: ["read", "ls"]
        case .review: []
        }
    }

    func allows(_ tool: String, readOnly: Bool = false) -> Bool {
        switch self {
        case .interactive: true
        case .scheduled: ["read", "ls", "skills_list", "skill_view"].contains(tool) || (tool.hasPrefix("mcp__") && readOnly)
        case .review: ["memory", "skills_list", "skill_view", "skill_manage"].contains(tool)
        }
    }
}
