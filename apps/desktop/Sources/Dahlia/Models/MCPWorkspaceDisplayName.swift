enum MCPWorkspaceDisplayName {
    static func resolve(for workspace: WorkspaceRecord, among workspaces: [WorkspaceRecord]) -> String {
        let hasDuplicateName = workspaces.contains { candidate in
            candidate.id != workspace.id && candidate.name == workspace.name
        }
        return hasDuplicateName ? "\(workspace.name) — \(workspace.path ?? workspace.id.uuidString)" : workspace.name
    }
}
