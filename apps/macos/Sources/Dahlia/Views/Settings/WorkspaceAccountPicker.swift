import SwiftUI

/// The account a workspace is listed under. Local and Databricks workspaces keep their data on this Mac.
enum WorkspaceAccountChoice: Hashable {
    case local
    case databricks(UUID)
    case dahlia(UUID)

    init(_ workspace: WorkspaceRecord) {
        self = workspace.accountConnectionId.map(Self.dahlia) ?? workspace.databricksConnectionId.map(Self.databricks) ?? .local
    }
}

struct WorkspaceAccountPicker: View {
    let workspace: WorkspaceRecord
    let connections: [DahliaAccountConnection]
    let databricksAccounts: [DatabricksConnection]
    let onSelect: (WorkspaceAccountChoice) async -> WorkspaceAccountChoice

    @State private var selection: WorkspaceAccountChoice
    @State private var updateTask: Task<Void, Never>?
    @State private var suppressNextChange = false

    init(
        workspace: WorkspaceRecord,
        connections: [DahliaAccountConnection],
        databricksAccounts: [DatabricksConnection],
        onSelect: @escaping (WorkspaceAccountChoice) async -> WorkspaceAccountChoice
    ) {
        self.workspace = workspace
        self.connections = connections
        self.databricksAccounts = databricksAccounts
        self.onSelect = onSelect
        _selection = State(initialValue: WorkspaceAccountChoice(workspace))
    }

    var body: some View {
        Picker(L10n.account, selection: $selection) {
            Text(L10n.localAccount).tag(WorkspaceAccountChoice.local)
            ForEach(databricksAccounts) { account in
                // Named as the Agents settings name its gateway.
                Text(L10n.unityGatewayHost(account.hostName)).tag(WorkspaceAccountChoice.databricks(account.id))
            }
            ForEach(connections) { connection in
                Text(accountLabel(connection)).tag(WorkspaceAccountChoice.dahlia(connection.id))
                    .disabled(!connection.isSignedIn || !connection.supportsWorkspaceSync)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .disabled(updateTask != nil)
        .onChange(of: selection) { oldValue, newValue in
            if suppressNextChange {
                suppressNextChange = false
                return
            }
            guard oldValue != newValue else { return }
            updateTask = Task {
                let persistedSelection = await onSelect(newValue)
                guard !Task.isCancelled else { return }
                if selection == newValue, persistedSelection != newValue {
                    suppressNextChange = true
                    selection = persistedSelection
                }
                updateTask = nil
            }
        }
        .onChange(of: WorkspaceAccountChoice(workspace)) { _, choice in
            updateTask?.cancel()
            updateTask = nil
            if selection != choice {
                suppressNextChange = true
                selection = choice
            }
        }
        .onDisappear {
            updateTask?.cancel()
            updateTask = nil
        }
    }

    private func accountLabel(_ connection: DahliaAccountConnection) -> String {
        "\(connection.displayName) · \(connection.isCloud ? L10n.dahliaCloud : L10n.dahliaServer)"
    }
}
