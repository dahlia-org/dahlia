import SwiftUI

/// Tools that the open account's chat agent can use. A Databricks account turns on its Unity AI Gateway MCPs here.
struct AgentSettingsView: View {
    @State private var workspaceSettings = WorkspaceAISettingsModel.shared

    var body: some View {
        if workspaceSettings.isDatabricksAccount, let connectionID = workspaceSettings.databricksAccountConnectionID {
            Section {
                ForEach(DatabricksGatewayMCP.allCases) { mcp in
                    GatewayMCPToggle(mcp: mcp, connectionID: connectionID)
                }
            } footer: {
                Text(L10n.unityGatewayMCPsDescription)
            }
            .id(connectionID)
        } else {
            Section {
                Text(L10n.agentMCPsRequireDatabricks).foregroundStyle(.secondary)
            }
        }
    }
}

private struct GatewayMCPToggle: View {
    let mcp: DatabricksGatewayMCP
    @AppStorage private var isOn: Bool

    init(mcp: DatabricksGatewayMCP, connectionID: UUID) {
        self.mcp = mcp
        _isOn = AppStorage(wrappedValue: false, mcp.defaultsKey(connectionID: connectionID))
    }

    var body: some View {
        // Chat reopens a thread's process with the new servers on its next message.
        Toggle(mcp.displayName, isOn: $isOn)
            .toggleStyle(.switch)
    }
}
