import SwiftUI

/// Chat agent settings: the Pi command this Mac runs, models, and the open account's MCPs.
struct AgentSettingsView: View {
    var body: some View {
        TabView {
            Form { AgentGeneralSettingsView() }
                .formStyle(.grouped)
                .tabItem { Text(L10n.general) }
            // shortcut: placeholder until agent model settings are designed.
            Form {
                Section { Text(L10n.agentModelsPlaceholder).foregroundStyle(.secondary) }
            }
            .formStyle(.grouped)
            .tabItem { Text(L10n.agentModels) }
            Form { AgentMCPSettingsView() }
                .formStyle(.grouped)
                .tabItem { Text(L10n.agentMCPs) }
        }
    }
}

private struct AgentGeneralSettingsView: View {
    @AppStorage(PiBundle.executablePathDefaultsKey) private var piPath = ""
    @State private var resolvedCommand: Result<String, CodexAppServerError>?

    var body: some View {
        Section {
            TextField(L10n.piCommand, text: $piPath, prompt: Text(L10n.piCommandAutomatic))
            LabeledContent(L10n.piCommandInUse) {
                switch resolvedCommand {
                case let .success(path):
                    Text(path).textSelection(.enabled)
                case let .failure(error):
                    Label(error.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                case nil:
                    EmptyView()
                }
            }
        } footer: {
            Text(L10n.piCommandDescription)
        }
        // Resolving checks the disk, so it runs off MainActor; Pi reads the saved path when each process starts.
        .task(id: piPath) {
            let resolved = await Task.detached {
                Result { try PiBundle.executableURL().path }.mapError { $0 as? CodexAppServerError ?? .piCommandNotFound(nil) }
            }.value
            // An edit cancels this task, but the detached lookup still finishes; drop its now-stale result.
            guard !Task.isCancelled else { return }
            resolvedCommand = resolved
        }
    }
}

/// MCPs grouped by where they come from; only Unity Gateway exists today.
private struct AgentMCPSettingsView: View {
    @State private var workspaceSettings = WorkspaceAISettingsModel.shared

    var body: some View {
        if workspaceSettings.isDatabricksAccount, let connectionID = workspaceSettings.databricksAccountConnectionID {
            Section {
                ForEach(DatabricksGatewayMCP.allCases) { mcp in
                    GatewayMCPToggle(mcp: mcp, connectionID: connectionID)
                }
            } header: {
                Text(L10n.unityGateway)
            } footer: {
                Text(L10n.unityGatewayMCPsDescription)
            }
            .id(connectionID)
        } else {
            Section {
                Text(L10n.agentMCPsRequireDatabricks).foregroundStyle(.secondary)
            } header: {
                Text(L10n.unityGateway)
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
        // Chat processes started after a change use the new servers; one already open keeps its own until it closes.
        Toggle(mcp.displayName, isOn: $isOn)
            .toggleStyle(.switch)
    }
}
