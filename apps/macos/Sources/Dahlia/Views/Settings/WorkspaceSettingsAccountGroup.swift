import Foundation

struct WorkspaceSettingsAccountGroup: Identifiable {
    let id: WorkspaceAccountChoice
    var workspaces: [WorkspaceRecord]

    static func grouped(
        _ workspaces: [WorkspaceRecord],
        including accounts: [WorkspaceAccountChoice] = [],
        hideLocalAccount: Bool = false
    ) -> [Self] {
        let ordered = workspaces.sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
        var groups: [Self] = []
        for account in accounts where !groups.contains(where: { $0.id == account }) {
            groups.append(Self(id: account, workspaces: []))
        }
        for workspace in ordered {
            let account = WorkspaceAccountChoice(workspace)
            if let index = groups.firstIndex(where: { $0.id == account }) {
                groups[index].workspaces.append(workspace)
            } else {
                groups.append(Self(id: account, workspaces: [workspace]))
            }
        }
        if let localIndex = groups.firstIndex(where: { $0.id == .local }) {
            groups.insert(groups.remove(at: localIndex), at: 0)
        }
        return hideLocalAccount ? groups.filter { $0.id != .local } : groups
    }
}
