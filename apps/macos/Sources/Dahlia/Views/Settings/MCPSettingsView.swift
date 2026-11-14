import AppKit
import SwiftUI

struct MCPSettingsView: View {
    let workspaces: [WorkspaceRecord]
    let currentWorkspace: WorkspaceRecord?
    let accountConnections: [DahliaAccountConnection]
    let databricksAccounts: [DatabricksConnection]
    private let helperURL: URL?

    @State private var selectedClient = MCPClient.codex
    @State private var selectedAccount: WorkspaceAccountChoice?
    @State private var selectedWorkspaceID: UUID?
    @State private var isWriteEnabled = false
    @State private var copiedContent: String?
    @State private var copyFeedbackTask: Task<Void, Never>?

    init(
        workspaces: [WorkspaceRecord],
        currentWorkspace: WorkspaceRecord?,
        accountConnections: [DahliaAccountConnection],
        databricksAccounts: [DatabricksConnection],
        helperURL: URL? = try? DahliaMCPBundle.executableURL()
    ) {
        self.workspaces = workspaces
        self.currentWorkspace = currentWorkspace
        self.accountConnections = accountConnections
        self.databricksAccounts = databricksAccounts
        self.helperURL = helperURL
    }

    var body: some View {
        Form {
            Section {
                Picker(L10n.mcpClient, selection: $selectedClient) {
                    ForEach(MCPClient.allCases) { client in
                        Text(client.displayName).font(.dahliaBody).tag(client)
                    }
                }
                .pickerStyle(.menu)
            } header: {
                Text(L10n.mcpChooseApp).font(.dahliaSectionHeader)
            }

            Section {
                MCPPreviewOptionsView(
                    selectedAccount: $selectedAccount,
                    selectedWorkspaceID: $selectedWorkspaceID,
                    accounts: accounts,
                    availableWorkspaces: accountWorkspaces,
                    accountName: accountName
                )
                DisclosureGroup(L10n.mcpIncludedWorkspaces(visibleWorkspaces.count)) {
                    ForEach(accounts, id: \.self) { account in
                        let included = visibleWorkspaces.filter { WorkspaceAccountChoice($0) == account }
                        ForEach(included) { workspace in
                            Text(MCPWorkspaceDisplayName.resolve(
                                for: workspace, among: included, accountName: accountName(account)
                            ))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                        }
                    }
                    if visibleWorkspaces.isEmpty {
                        Text(L10n.mcpNoWorkspaces).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(L10n.mcpChooseScope).font(.dahliaSectionHeader)
            } footer: {
                Text(L10n.mcpFooter)
            }

            Section {
                Toggle(L10n.mcpAllowWriteAccess, isOn: $isWriteEnabled)
                    .toggleStyle(.switch)
                Label(
                    isWriteEnabled ? L10n.mcpReadWrite : L10n.mcpReadOnly,
                    systemImage: isWriteEnabled ? "pencil" : "eye"
                )
                .foregroundStyle(.secondary)
            } header: {
                Text(L10n.mcpPermissions).font(.dahliaSectionHeader)
            } footer: {
                Text(L10n.mcpWriteExplanation)
            }

            if let commands {
                Section {
                    Text(selectedClient == .mcpJSON ? L10n.mcpJSONInstructions : L10n.mcpCommandInstructions)
                        .foregroundStyle(.secondary)
                    switch selectedClient {
                    case .codex, .claude:
                        if let command = commands.registrationCommand(for: selectedClient, writeEnabled: isWriteEnabled),
                           let removalCommand = commands.removalCommand(for: selectedClient) {
                            MCPCommandView(
                                title: selectedClient.displayName,
                                command: command,
                                removalCommand: removalCommand,
                                copiedCommand: copiedContent,
                                onCopy: copy
                            )
                        }
                    case .mcpJSON:
                        if let sample = commands.mcpJSONSample(writeEnabled: isWriteEnabled) {
                            MCPJSONSampleView(
                                sample: sample,
                                isCopied: copiedContent == sample,
                                onCopy: copy
                            )
                        }
                    }
                } header: {
                    Text(L10n.mcpConfigurationOutput)
                        .font(.dahliaSectionHeader)
                }
            } else {
                Section {
                    Text(scopeIsUnavailable ? L10n.mcpScopeUnavailable : L10n.mcpHelperUnavailable)
                        .foregroundStyle(DahliaDesign.secondaryTextColor)
                } header: {
                    Text(L10n.mcpConfigurationOutput)
                        .font(.dahliaSectionHeader)
                }
            }

        }
        .formStyle(.grouped)
        .disclosureGroupStyle(MCPDisclosureGroupStyle())
        .font(.dahliaBody)
        .onDisappear {
            copyFeedbackTask?.cancel()
        }
    }

    private var availableWorkspaces: [WorkspaceRecord] {
        guard let currentWorkspace,
              !workspaces.contains(where: { $0.id == currentWorkspace.id }) else {
            return workspaces
        }
        return [currentWorkspace] + workspaces
    }

    private var accounts: [WorkspaceAccountChoice] {
        var result: [WorkspaceAccountChoice] = [.local]
        result += databricksAccounts.map { .databricks($0.id) }
        result += accountConnections.map { .dahlia($0.id) }
        for workspace in availableWorkspaces {
            let account = WorkspaceAccountChoice(workspace)
            if !result.contains(account) { result.append(account) }
        }
        return result
    }

    private func accountName(_ account: WorkspaceAccountChoice) -> String {
        account.displayName(connections: accountConnections, databricksAccounts: databricksAccounts)
    }

    private var accountWorkspaces: [WorkspaceRecord] {
        availableWorkspaces.filter { WorkspaceAccountChoice($0) == selectedAccount }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var visibleWorkspaces: [WorkspaceRecord] {
        let workspaces = selectedAccount == nil ? availableWorkspaces : accountWorkspaces
        return selectedWorkspaceID.map { id in workspaces.filter { $0.id == id } } ?? workspaces
    }

    private var scopeIsUnavailable: Bool {
        !(selectedAccount.map { accounts.contains($0) } ?? true)
            || MCPAccessScope.resolve(account: selectedAccount, workspaceID: selectedWorkspaceID, workspaces: availableWorkspaces) == nil
    }

    private var commands: MCPRegistrationCommands? {
        guard selectedAccount.map({ accounts.contains($0) }) ?? true,
              let scope = MCPAccessScope.resolve(account: selectedAccount, workspaceID: selectedWorkspaceID, workspaces: availableWorkspaces),
              let helperURL else { return nil }
        return MCPRegistrationCommands(helperURL: helperURL, scope: scope)
    }

    private func copy(_ command: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        copiedContent = command

        copyFeedbackTask?.cancel()
        copyFeedbackTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
            copiedContent = nil
        }
    }
}
