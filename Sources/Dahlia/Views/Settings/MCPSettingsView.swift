import AppKit
import SwiftUI

struct MCPSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var copiedCommandTitle: String?
    @State private var copyFeedbackTask: Task<Void, Never>?

    var body: some View {
        Form {
            Section {
                if let vault = settings.currentVault {
                    LabeledContent(L10n.vaultName, value: vault.name)
                    LabeledContent(L10n.vaultID, value: vault.id.uuidString)
                        .textSelection(.enabled)

                    if let commands = commands(for: vault) {
                        commandContent(
                            title: L10n.codexCLI,
                            command: commands.codex
                        )
                        commandContent(
                            title: L10n.claudeCode,
                            command: commands.claude
                        )
                    } else {
                        Text(L10n.mcpHelperUnavailable)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ContentUnavailableView(
                        L10n.noVaultSelected,
                        systemImage: "externaldrive.badge.questionmark",
                        description: Text(L10n.selectVaultForMCP)
                    )
                }
            } header: {
                Text(L10n.mcp)
            } footer: {
                Text(L10n.mcpFooter)
            }
        }
        .formStyle(.grouped)
        .onDisappear {
            copyFeedbackTask?.cancel()
        }
    }

    private func commandContent(title: String, command: String) -> some View {
        LabeledContent {
            VStack(alignment: .trailing, spacing: 8) {
                Text(command)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .multilineTextAlignment(.leading)
                    .accessibilityLabel(L10n.registrationCommand(title))
                Button(
                    copiedCommandTitle == title ? L10n.copied : L10n.copyCommand,
                    systemImage: copiedCommandTitle == title ? "checkmark" : "doc.on.doc"
                ) {
                    copy(command, title: title)
                }
            }
        } label: {
            Text(title)
        }
    }

    private func commands(for vault: VaultRecord) -> MCPRegistrationCommands? {
        guard let helperURL = try? DahliaMCPBundle.executableURL() else { return nil }
        return MCPRegistrationCommands(
            helperURL: helperURL,
            vaultID: vault.id
        )
    }

    private func copy(_ command: String, title: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        copiedCommandTitle = title

        copyFeedbackTask?.cancel()
        copyFeedbackTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
            copiedCommandTitle = nil
        }
    }
}
