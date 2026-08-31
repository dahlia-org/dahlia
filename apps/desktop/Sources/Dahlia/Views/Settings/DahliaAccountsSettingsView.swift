import SwiftUI

struct DahliaAccountsSettingsView: View {
    let controller: DahliaCloudAccountController
    let onShowSignIn: () -> Void

    @State private var pendingSignOut: DahliaAccountConnection?
    @State private var pendingRemoval: DahliaAccountConnection?
    @State private var isShowingSignOutConfirmation = false
    @State private var isShowingRemovalConfirmation = false

    var body: some View {
        Form {
            Section {
                ForEach(controller.connections) { connection in
                    connectionRow(connection)
                }

                Button(L10n.dahliaSignIn, action: onShowSignIn)
                    .disabled(controller.isBusy)
            } footer: {
                Text(L10n.dahliaAccountsDescription)
            }

            if let errorMessage = controller.errorMessage {
                Section {
                    SettingsStatusMessage(
                        text: errorMessage,
                        systemImage: "exclamationmark.triangle.fill",
                        tint: .red
                    )
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            pendingSignOut.map { L10n.signOutDahliaConnection($0.displayName) } ?? "",
            isPresented: $isShowingSignOutConfirmation,
            titleVisibility: .visible
        ) {
            if let connection = pendingSignOut {
                Button(L10n.signOut, role: .destructive) {
                    controller.startSignOut(connectionID: connection.id)
                    pendingSignOut = nil
                }
            }
            Button(L10n.cancel, role: .cancel) { pendingSignOut = nil }
        } message: {
            Text(L10n.signOutDahliaConnectionDescription)
        }
        .confirmationDialog(
            pendingRemoval.map { L10n.removeDahliaConnection($0.displayName) } ?? "",
            isPresented: $isShowingRemovalConfirmation,
            titleVisibility: .visible
        ) {
            if let connection = pendingRemoval {
                Button(L10n.remove, role: .destructive) {
                    controller.startRemove(connectionID: connection.id)
                    pendingRemoval = nil
                }
            }
            Button(L10n.cancel, role: .cancel) { pendingRemoval = nil }
        } message: {
            Text(L10n.removeDahliaConnectionDescription)
        }
    }

    private func connectionRow(_ connection: DahliaAccountConnection) -> some View {
        LabeledContent {
            if controller.isBusy(connectionID: connection.id) {
                ProgressView()
                    .controlSize(.small)
            } else if connection.isSignedIn {
                Button(L10n.signOut) {
                    pendingSignOut = connection
                    isShowingSignOutConfirmation = true
                }
                .disabled(controller.isBusy)
            } else {
                HStack {
                    Button(L10n.reauthenticate) {
                        controller.startReauthentication(connectionID: connection.id)
                    }
                    Button(L10n.remove, role: .destructive) {
                        pendingRemoval = connection
                        isShowingRemovalConfirmation = true
                    }
                }
                .disabled(controller.isBusy)
            }
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(connection.displayName)
                    Text(connection.isSignedIn ? connection.origin : L10n.signInRequired)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: connection.isCloud ? "icloud" : "xserve")
                    .foregroundStyle(connection.isSignedIn ? .green : .secondary)
            }
        }
    }
}
