import AppKit
import SwiftUI

struct MeetingDataAccessSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared

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
                        Text(L10n.meetingDataAccessHelperUnavailable)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ContentUnavailableView(
                        L10n.noVaultSelected,
                        systemImage: "externaldrive.badge.questionmark",
                        description: Text(L10n.selectVaultForMeetingDataAccess)
                    )
                }
            } header: {
                Text(L10n.meetingDataAccess)
            } footer: {
                Text(L10n.meetingDataAccessFooter)
            }
        }
        .formStyle(.grouped)
    }

    private func commandContent(title: String, command: String) -> some View {
        LabeledContent {
            VStack(alignment: .trailing, spacing: 8) {
                Text(command)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .multilineTextAlignment(.leading)
                    .accessibilityLabel(L10n.registrationCommand(title))
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                } label: {
                    Label(L10n.copyCommand, systemImage: "doc.on.doc")
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
}
