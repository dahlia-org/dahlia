import AppKit
import SwiftUI

struct MCPSettingsView: View {
    let workspaces: [WorkspaceRecord]
    let currentWorkspace: WorkspaceRecord?

    @State private var selectedClient = MCPClient.codex
    @State private var selectedWorkspaceID: UUID?
    @State private var isWriteEnabled = false
    @State private var copiedContent: String?
    @State private var copyFeedbackTask: Task<Void, Never>?

    init(workspaces: [WorkspaceRecord], currentWorkspace: WorkspaceRecord?) {
        self.workspaces = workspaces
        self.currentWorkspace = currentWorkspace
        _selectedWorkspaceID = State(initialValue: nil)
    }

    var body: some View {
        Form {
            Section {
                MCPPreviewOptionsView(
                    selectedClient: $selectedClient,
                    selectedWorkspaceID: $selectedWorkspaceID,
                    isWriteEnabled: $isWriteEnabled,
                    availableWorkspaces: availableWorkspaces
                )
            } header: {
                Text(L10n.mcpPreview)
            } footer: {
                Text(L10n.mcpFooter)
            }

            if let commands = commands(for: selectedWorkspace) {
                Section(L10n.mcpConfigurationOutput) {
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
                }
            } else {
                Section(L10n.mcpConfigurationOutput) {
                    Text(L10n.mcpHelperUnavailable)
                        .foregroundStyle(DahliaDesign.secondaryTextColor)
                }
            }

        }
        .formStyle(.grouped)
        .onAppear(perform: reconcileSelectedWorkspace)
        .onChange(of: workspaces) {
            reconcileSelectedWorkspace()
        }
        .onChange(of: currentWorkspace?.id) {
            reconcileSelectedWorkspace()
        }
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

    private var selectedWorkspace: WorkspaceRecord? {
        availableWorkspaces.first { $0.id == selectedWorkspaceID }
    }

    private func commands(for workspace: WorkspaceRecord?) -> MCPRegistrationCommands? {
        guard let helperURL = try? DahliaMCPBundle.executableURL() else { return nil }
        return MCPRegistrationCommands(
            helperURL: helperURL,
            workspaceID: workspace?.id
        )
    }

    private func reconcileSelectedWorkspace() {
        if selectedWorkspaceID != nil, selectedWorkspace == nil { selectedWorkspaceID = nil }
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
