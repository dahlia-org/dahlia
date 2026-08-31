import SwiftUI

struct DahliaCloudAccountSettingsView: View {
    let controller: DahliaCloudAccountController
    let onShowSignIn: () -> Void
    let onCancelSignIn: () -> Void
    let onSignOut: () -> Void

    var body: some View {
        Section {
            HStack {
                accountStatus
                Spacer()
                accountAction
            }

            if let errorMessage = controller.errorMessage {
                SettingsStatusMessage(
                    text: errorMessage,
                    systemImage: "exclamationmark.triangle.fill",
                    tint: .red
                )
            }

        } header: {
            Text(L10n.dahliaAccount)
        }
    }

    @ViewBuilder
    private var accountStatus: some View {
        if controller.isSigningIn {
            SettingsStatusMessage(text: L10n.dahliaWaitingForBrowser, systemImage: "safari", tint: .secondary)
        } else if controller.isRefreshing || controller.isSigningOut {
            ProgressView()
                .controlSize(.small)
        } else if let account = controller.account {
            SettingsStatusMessage(
                text: controller.connectionStatus ?? L10n.dahliaSignedInAs(account.displayName),
                detail: controller.connectionDetail,
                systemImage: controller.connectionSystemImage,
                tint: .green
            )
        } else {
            SettingsStatusMessage(text: L10n.dahliaNotSignedIn, systemImage: "icloud.slash", tint: .secondary)
        }
    }

    @ViewBuilder
    private var accountAction: some View {
        if controller.isSigningIn {
            Button(L10n.cancelSignIn, action: onCancelSignIn)
                .buttonStyle(.dahlia())
        } else if controller.account != nil {
            Button(L10n.signOut, action: onSignOut)
                .buttonStyle(.dahlia())
                .disabled(controller.isBusy)
        } else {
            Button(L10n.dahliaSignIn, action: onShowSignIn)
                .buttonStyle(.dahlia(.primary))
                .disabled(controller.isBusy)
        }
    }
}
