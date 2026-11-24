import Foundation

enum MCPWorkspaceDisplayName {
    static func resolve(for workspace: WorkspaceRecord, among workspaces: [WorkspaceRecord]) -> String {
        let hasDuplicateName = workspaces.contains { $0.id != workspace.id && $0.name == workspace.name }
        return hasDuplicateName ? "\(workspace.name) — \(workspace.path ?? String(workspace.id.uuidString.suffix(8)))" : workspace.name
    }
}
