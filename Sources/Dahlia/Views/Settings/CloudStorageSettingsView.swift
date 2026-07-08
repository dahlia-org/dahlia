import SwiftUI

struct CloudStorageSettingsView: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var driveStore = GoogleDriveStore.shared

    var body: some View {
        Form {
            Section {
                connectionRow

                if let message = driveStore.lastErrorMessage {
                    SettingsStatusMessage(
                        text: message,
                        systemImage: "exclamationmark.triangle",
                        tint: .orange
                    )
                }
            } header: {
                Text(L10n.googleDrive)
            } footer: {
                Text(L10n.googleDriveSettingsDescription)
            }

            Section {
                LabeledContent {
                    Button {
                        openWindow(id: WindowID.projectManager)
                    } label: {
                        Label(L10n.manageProjects, systemImage: "folder")
                    }
                } label: {
                    Text(L10n.projectManagement)
                    Text(L10n.summaryDestinationsDescription)
                }
            } header: {
                Text(L10n.projectDriveFolders)
            } footer: {
                Text(L10n.projectDriveFoldersDescription)
            }
        }
        .formStyle(.grouped)
        .task {
            await driveStore.restoreSessionIfNeeded()
        }
    }

    private var connectionRow: some View {
        LabeledContent {
            actionButton
        } label: {
            Text(driveStore.account?.displayName ?? L10n.googleDriveNotConnected)
            Text(accountSubtitle)
        }
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
