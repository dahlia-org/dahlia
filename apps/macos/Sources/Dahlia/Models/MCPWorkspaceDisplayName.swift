import Foundation

enum MCPWorkspaceDisplayName {
    static func resolve(for workspace: WorkspaceRecord, among workspaces: [WorkspaceRecord], accountName: String) -> String {
        "\(resolve(for: workspace, among: workspaces)) - \(accountName)"
    }

    static func resolve(for workspace: WorkspaceRecord, among workspaces: [WorkspaceRecord]) -> String {
        let hasDuplicateName = workspaces.contains { candidate in
            candidate.id != workspace.id && candidate.name == workspace.name
                && WorkspaceAccountChoice(candidate) == WorkspaceAccountChoice(workspace)
        }
        return hasDuplicateName ? "\(workspace.name) — \(workspace.path ?? String(workspace.id.uuidString.suffix(8)))" : workspace.name
    }
}
