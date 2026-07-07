import SwiftUI

struct CloudStorageSettingsView: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var driveStore = GoogleDriveStore.shared

    var body: some View {
        SettingsPage {
            SettingsSection(
                title: L10n.googleDrive,
                description: L10n.googleDriveSettingsDescription
            ) {
                SettingsCard {
                    connectionRow

                    if let message = driveStore.lastErrorMessage {
                        Divider()

                        SettingsStatusMessage(
                            text: message,
                            systemImage: "exclamationmark.triangle",
                            tint: .orange
                        )
                        .padding(20)
                    }
                }
            }

            SettingsSection(
                title: L10n.projectDriveFolders,
                description: L10n.projectDriveFoldersDescription
            ) {
                SettingsCard {
                    SettingsControlRow(
                        title: L10n.projectManagement,
                        description: L10n.summaryDestinationsDescription
                    ) {
                        Button {
                            openWindow(id: WindowID.projectManager)
                        } label: {
                            Label(L10n.manageProjects, systemImage: "folder")
                        }
                    }
                }
            }
        }
        .task {
            await driveStore.restoreSessionIfNeeded()
        }
    }

    private var connectionRow: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text(driveStore.account?.displayName ?? L10n.googleDriveNotConnected)
                    .font(.headline)

                Text(accountSubtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            actionButton
        }
        .padding(20)
    }

    @ViewBuilder
    private var actionButton: some View {
        if !driveStore.isAuthorized {
            Button(L10n.googleDriveConnect) {
                Task {
                    await driveStore.signIn()
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!driveStore.isConfigured || driveStore.isBusy)
        } else {
            Button(L10n.googleDriveDisconnect) {
                Task {
                    await driveStore.disconnect()
                }
            }
            .buttonStyle(.bordered)
            .disabled(!driveStore.isConfigured || driveStore.isBusy)
        }
    }

    private var accountSubtitle: String {
        if !driveStore.isConfigured {
            return L10n.googleAccountClientIDMissingMessage
        }

        if let account = driveStore.account, driveStore.isAuthorized {
            return account.email.isEmpty ? L10n.googleDriveConnected : account.email
        }

        return L10n.googleDriveConnectDescription
    }

}
