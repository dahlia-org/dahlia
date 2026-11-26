import AppKit
import SwiftUI

struct MCPSettingsView: View {
    let workspaces: [WorkspaceRecord]
    let currentWorkspace: WorkspaceRecord?
    private let helperURL: URL?

    @State private var selectedClient = MCPClient.claude
    @State private var isWorkspacesExpanded = false
    @State private var selectedWorkspaceID: UUID?
    @State private var isWriteEnabled = false
    @State private var copiedContent: String?
    @State private var copyFeedbackTask: Task<Void, Never>?

    init(
        workspaces: [WorkspaceRecord],
        currentWorkspace: WorkspaceRecord?,
        helperURL: URL? = try? DahliaMCPBundle.executableURL()
    ) {
        self.workspaces = workspaces
        self.currentWorkspace = currentWorkspace
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
                MCPPreviewOptionsView(selectedWorkspaceID: $selectedWorkspaceID, availableWorkspaces: sortedWorkspaces)
                DisclosureGroup(L10n.mcpIncludedWorkspaces(visibleWorkspaces.count), isExpanded: $isWorkspacesExpanded) {
                    ForEach(visibleWorkspaces) { workspace in
                        Text(MCPWorkspaceDisplayName.resolve(for: workspace, among: visibleWorkspaces))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
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
                    .toggleStyle(.dahliaSwitch)
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

    private var sortedWorkspaces: [WorkspaceRecord] {
        availableWorkspaces.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var visibleWorkspaces: [WorkspaceRecord] {
        selectedWorkspaceID.map { id in sortedWorkspaces.filter { $0.id == id } } ?? sortedWorkspaces
    }

    private var scopeIsUnavailable: Bool {
        MCPAccessScope.resolve(workspaceID: selectedWorkspaceID, workspaces: availableWorkspaces) == nil
    }

    private var commands: MCPRegistrationCommands? {
        guard let scope = MCPAccessScope.resolve(workspaceID: selectedWorkspaceID, workspaces: availableWorkspaces),
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
