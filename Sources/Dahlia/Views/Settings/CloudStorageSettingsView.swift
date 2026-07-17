import SwiftUI

struct CloudStorageSettingsView: View {
    @ObservedObject private var driveStore = GoogleDriveStore.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var exportFolderStatusMessage: String?
    @State private var exportFolderAlertMessage = ""
    @State private var isShowingExportFolderAlert = false

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
                Text(L10n.googleDocs)
            } footer: {
                Text(L10n.googleDocsSettingsDescription)
            }

            Section {
                LabeledContent {
                    Text(AppSettings.defaultGoogleDriveExportFolderName)
                } label: {
                    Text(L10n.googleDriveExportFolder)
                    Text(L10n.myDrive)
                }

                if let exportFolderURL {
                    Link(destination: exportFolderURL) {
                        Label(L10n.openInGoogleDrive, systemImage: "arrow.up.right.square")
                    }
                }

                if let exportFolderStatusMessage {
                    SettingsStatusMessage(
                        text: exportFolderStatusMessage,
                        systemImage: "exclamationmark.triangle",
                        tint: .orange
                    )
                }
            } header: {
                Text(L10n.googleDriveExportDestination)
            } footer: {
                Text(L10n.googleDriveExportDestinationDescription)
            }
        }
        .formStyle(.grouped)
        .task {
            await driveStore.restoreSessionIfNeeded()
            await driveStore.refreshExportFolderConfiguration()
            if let message = driveStore.exportFolderErrorMessage {
                presentExportFolderError(message)
            }
        }
        .onChange(of: driveStore.isAuthorized) { _, isAuthorized in
            guard !isAuthorized else { return }
            resetExportFolderStatus()
        }
        .onChange(of: driveStore.account?.id) { _, _ in
            resetExportFolderStatus()
        }
        .onChange(of: driveStore.exportFolderErrorMessage) { _, message in
            guard let message else { return }
            presentExportFolderError(message)
        }
        .alert(L10n.googleDriveExportFolderConfigurationFailed, isPresented: $isShowingExportFolderAlert) {
            Button(L10n.close, role: .cancel) {}
        } message: {
            Text(exportFolderAlertMessage)
        }
    }

    private var connectionRow: some View {
        LabeledContent {
            actionButton
        } label: {
            Text(driveStore.account?.displayName ?? L10n.googleDocsNotConnected)
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
            return account.email.isEmpty ? L10n.googleDocsConnected : account.email
        }

        return L10n.googleDocsConnectDescription
    }

    private var exportFolderURL: URL? {
        guard let accountID = driveStore.account?.id else { return nil }
        return settings.googleDriveExportFolderURL(forAccountID: accountID)
    }

    private func presentExportFolderError(_ message: String) {
        exportFolderStatusMessage = message
        exportFolderAlertMessage = message
        isShowingExportFolderAlert = true
    }

    private func resetExportFolderStatus() {
        exportFolderStatusMessage = nil
    }
}
