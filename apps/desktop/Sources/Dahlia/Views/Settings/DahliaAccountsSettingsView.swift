import SwiftUI

struct DahliaAccountsSettingsView: View {
    let controller: DahliaCloudAccountController
    let currentWorkspace: WorkspaceRecord?
    let workspaces: [WorkspaceRecord]
    let canSwitchAccount: Bool
    let onSelectWorkspace: (WorkspaceRecord) -> Void
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
                Text(pendingRemoval.map { L10n.removeDahliaConnectionDescription(workspaceCount: $0.workspaceCount) }
                    ?? L10n.removeDahliaConnectionDescription(workspaceCount: 0))
            }
    }

    @ViewBuilder
    private var sections: some View {
        Section {
            selectionRow(connection: nil) {
                HStack {
                    Label(L10n.localAccount, systemImage: "desktopcomputer")
                    selectionMark(connectionID: nil)
                }
                .accessibilityHidden(true)
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
        selectionRow(connection: connection) {
            HStack {
                HStack {
                    Image(systemName: connection.isCloud ? "icloud" : "xserve")
                        .foregroundStyle(connection.isSignedIn ? .green : .secondary)

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
                .accessibilityHidden(true)

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
    }

    private func selectionRow(
        connection: DahliaAccountConnection?,
        @ViewBuilder label: () -> some View
    ) -> some View {
        let isSelected = currentWorkspace != nil && currentWorkspace?.accountConnectionId == connection?.id
        let canSelect = workspaceToSelect(for: connection) != nil
        return label()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background {
                Button {
                    selectAccount(connection)
                } label: {
                    Color.clear
                        .contentShape(.rect(cornerRadius: DahliaDesign.Highlight.compactCornerRadius))
                }
                .buttonStyle(.plain)
                .disabled(!canSelect)
                .accessibilityLabel(connection?.displayName ?? L10n.localAccount)
                .accessibilityValue(connection?.origin ?? "")
                .accessibilityHint(isSelected ? "" : L10n.switchAccount)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
            .modifier(AccountRowHoverModifier(isEnabled: canSelect))
    }

    func selectAccount(_ connection: DahliaAccountConnection?) {
        guard let workspace = workspaceToSelect(for: connection) else { return }
        onSelectWorkspace(workspace)
    }

    private func workspaceToSelect(for connection: DahliaAccountConnection?) -> WorkspaceRecord? {
        guard canSwitchAccount, !controller.isBusy, connection?.isSignedIn != false else { return nil }
        return MainSidebarFooterView.workspaceToSelect(
            from: workspaces,
            currentWorkspace: currentWorkspace,
            connectionID: connection?.id
        )
    }

    @ViewBuilder
    private func selectionMark(connectionID: UUID?) -> some View {
        if let currentWorkspace, currentWorkspace.accountConnectionId == connectionID {
            Image(systemName: "checkmark")
                .foregroundStyle(.tint)
                .accessibilityLabel(L10n.selectedAccount)
        }
    }
}

private struct AccountRowHoverModifier: ViewModifier {
    let isEnabled: Bool
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background(
                isEnabled && isHovered ? DahliaDesign.sidebarHighlightColor : .clear,
                in: .rect(cornerRadius: DahliaDesign.Highlight.compactCornerRadius)
            )
            .onHover { isHovered = $0 }
    }
}
