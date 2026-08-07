import AppKit
import SwiftUI

struct MCPSettingsView: View {
    var sidebarViewModel: SidebarViewModel

    @ObservedObject private var settings = AppSettings.shared
    @State private var selectedClient = MCPClient.codex
    @State private var selectedVaultID: UUID?
    @State private var isWriteEnabled = false
    @State private var copiedContent: String?
    @State private var copyFeedbackTask: Task<Void, Never>?

    init(sidebarViewModel: SidebarViewModel) {
        self.sidebarViewModel = sidebarViewModel
        _selectedVaultID = State(initialValue: sidebarViewModel.currentVault?.id ?? sidebarViewModel.allVaults.first?.id)
    }

    var body: some View {
        Form {
            if let vault = selectedVault {
                Section {
                    MCPPreviewOptionsView(
                        selectedClient: $selectedClient,
                        selectedVaultID: $selectedVaultID,
                        isWriteEnabled: $isWriteEnabled,
                        availableVaults: availableVaults
                    )
                } header: {
                    Text(L10n.mcpPreview)
                } footer: {
                    Text(L10n.mcpFooter)
                }

                if let commands = commands(for: vault) {
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
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                ContentUnavailableView(
                    L10n.noVaultSelected,
                    systemImage: "externaldrive.badge.questionmark",
                    description: Text(L10n.selectVaultForMCP)
                )
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: reconcileSelectedVault)
        .onChange(of: sidebarViewModel.allVaults) {
            reconcileSelectedVault()
        }
        .onChange(of: settings.currentVault?.id) {
            reconcileSelectedVault()
        }
        .onDisappear {
            copyFeedbackTask?.cancel()
        }
    }

    private var availableVaults: [VaultRecord] {
        guard let currentVault = settings.currentVault,
              !sidebarViewModel.allVaults.contains(where: { $0.id == currentVault.id }) else {
            return sidebarViewModel.allVaults
        }
        return [currentVault] + sidebarViewModel.allVaults
    }

    private var selectedVault: VaultRecord? {
        availableVaults.first { $0.id == selectedVaultID }
    }

    private func commands(for vault: VaultRecord) -> MCPRegistrationCommands? {
        guard let helperURL = try? DahliaMCPBundle.executableURL() else { return nil }
        return MCPRegistrationCommands(
            helperURL: helperURL,
            vaultID: vault.id
        )
    }

    private func reconcileSelectedVault() {
        guard selectedVault == nil else { return }
        selectedVaultID = settings.currentVault?.id ?? availableVaults.first?.id
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
