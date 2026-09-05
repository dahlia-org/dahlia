import SwiftUI

struct DahliaAccountsSettingsView: View {
    let controller: DahliaCloudAccountController
    let currentVault: VaultRecord?
    let onShowSignIn: () -> Void

    @State private var pendingRemoval: DahliaAccountConnection?
    @State private var isShowingRemovalConfirmation = false

    var body: some View {
        sections
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
                Text(pendingRemoval.map { L10n.removeDahliaConnectionDescription(vaultCount: $0.vaultCount) }
                    ?? L10n.removeDahliaConnectionDescription(vaultCount: 0))
            }
    }

    @ViewBuilder
    private var sections: some View {
        Section {
            HStack {
                Label(L10n.localAccount, systemImage: "desktopcomputer")
                selectionMark(connectionID: nil)
            }
            ForEach(controller.connections) { connection in
                connectionRow(connection)
            }
        } header: {
            HStack {
                Text(L10n.account)

                Spacer()

                Button(L10n.dahliaSignIn, action: onShowSignIn)
                    .buttonStyle(.dahlia(.primary))
                    .controlSize(.small)
                    .disabled(controller.isBusy)
            }
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

    private func connectionRow(_ connection: DahliaAccountConnection) -> some View {
        HStack {
            HStack {
                Image(systemName: connection.isCloud ? "icloud" : "xserve")
                    .foregroundStyle(connection.isSignedIn ? .green : .secondary)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(connection.displayName)
                        selectionMark(connectionID: connection.id)
                    }
                    Text(connection.isSignedIn ? connection.origin : L10n.signInRequired)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if controller.isBusy(connectionID: connection.id) {
                ProgressView()
                    .controlSize(.small)
            } else if connection.isSignedIn {
                Button(L10n.signOut) {
                    controller.requestSignOut(connectionID: connection.id)
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
        }
    }

    @ViewBuilder
    private func selectionMark(connectionID: UUID?) -> some View {
        if let currentVault, currentVault.accountConnectionId == connectionID {
            Image(systemName: "checkmark")
                .foregroundStyle(.tint)
                .accessibilityLabel(L10n.selectedAccount)
        }
    }
}
