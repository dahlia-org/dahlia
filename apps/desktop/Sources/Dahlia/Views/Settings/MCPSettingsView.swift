import AppKit
import SwiftUI

struct MCPSettingsView: View {
    let vaults: [VaultRecord]
    let currentVault: VaultRecord?

    @State private var selectedClient = MCPClient.codex
    @State private var selectedVaultID: UUID?
    @State private var isWriteEnabled = false
    @State private var copiedContent: String?
    @State private var copyFeedbackTask: Task<Void, Never>?

    init(vaults: [VaultRecord], currentVault: VaultRecord?) {
        self.vaults = vaults
        self.currentVault = currentVault
        _selectedVaultID = State(initialValue: nil)
    }

    var body: some View {
        Form {
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

            if let commands = commands(for: selectedVault) {
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
        .onAppear(perform: reconcileSelectedVault)
        .onChange(of: vaults) {
            reconcileSelectedVault()
        }
        .onChange(of: currentVault?.id) {
            reconcileSelectedVault()
        }
        .onDisappear {
            copyFeedbackTask?.cancel()
        }
    }

    private var availableVaults: [VaultRecord] {
        guard let currentVault,
              !vaults.contains(where: { $0.id == currentVault.id }) else {
            return vaults
        }
        return [currentVault] + vaults
    }

    private var selectedVault: VaultRecord? {
        availableVaults.first { $0.id == selectedVaultID }
    }

    private func commands(for vault: VaultRecord?) -> MCPRegistrationCommands? {
        guard let helperURL = try? DahliaMCPBundle.executableURL() else { return nil }
        return MCPRegistrationCommands(
            helperURL: helperURL,
            vaultID: vault?.id
        )
    }

    private func reconcileSelectedVault() {
        if selectedVaultID != nil, selectedVault == nil { selectedVaultID = nil }
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
