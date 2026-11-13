import AppKit
import SwiftUI

/// Adds a Databricks workspace (each is its own account) or continues with the Local Account. It keeps the layout of
/// `DahliaServerSignInView`, whose Dahlia Cloud and Server sign-in is hidden for now.
struct DatabricksSignInView: View {
    var isEmbedded = false
    /// Hidden once a Local Account workspace exists; the account list switches to it instead.
    var showsLocalAccount = true
    let workspaceManagementModel: WorkspaceManagementModel
    var canTransferWorkspace = true
    let onCancel: () -> Void
    let onContinueWithDatabricks: (UUID) -> Void
    let onContinueLocally: () -> Void
    var onInteractionStateChange: (Bool) -> Void = { _ in }

    @State private var controller = DatabricksAccountController()
    @State private var pendingConnectionID: UUID?
    @State private var isTransferringWorkspace = false
    @State private var transferError: String?
    @State private var workspaceURL = ""
    @State private var signInTask: Task<Void, Never>?
    @State private var isCloseHovered = false

    var body: some View {
        Group {
            if let pendingConnectionID {
                DatabricksWorkspaceSetupView(
                    workspaces: workspaceManagementModel.workspaceTransferCandidates(toDatabricks: pendingConnectionID),
                    isEmbedded: isEmbedded,
                    isBusy: isTransferringWorkspace,
                    canTransferWorkspace: canTransferWorkspace,
                    errorMessage: transferError,
                    onCancel: cancel,
                    onCreate: { completeSignIn(pendingConnectionID) },
                    onTransfer: { transfer($0, to: pendingConnectionID) }
                )
            } else {
                signInContent
            }
        }
        .onChange(of: signInTask != nil || pendingConnectionID != nil, initial: true) { _, isActive in
            onInteractionStateChange(isActive)
        }
        .onDisappear {
            signInTask?.cancel()
            onInteractionStateChange(false)
        }
    }

    private var signInContent: some View {
        ZStack {
            if !isEmbedded {
                Color.black.opacity(0.16)
                    .ignoresSafeArea()
                    .contentShape(.rect)
            }

            VStack(spacing: 20) {
                HStack(spacing: 12) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 64, height: 64)
                        .accessibilityHidden(true)
                    Text(L10n.dahlia)
                        .font(.dahliaLargeTitle)
                        .bold()
                        .accessibilityAddTraits(.isHeader)
                }

                Text(L10n.accountSetupDescription)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if controller.isBusy {
                    ProgressView()
                        .controlSize(.small)
                    Text(L10n.dahliaWaitingForBrowser)
                        .foregroundStyle(.secondary)

                    Button(L10n.cancelSignIn) { signInTask?.cancel() }
                        .buttonStyle(.dahlia())
                } else {
                    if let errorMessage = controller.errorMessage {
                        SettingsStatusMessage(
                            text: errorMessage,
                            systemImage: "exclamationmark.triangle.fill",
                            tint: .red
                        )
                    }

                    // Signing in to an already connected workspace refreshes it and opens its account.
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.databricksWorkspaceURL)
                            .font(.dahliaBody)
                        TextField(L10n.databricksWorkspaceURLPlaceholder, text: $workspaceURL)
                            .textContentType(.URL)
                            .onSubmit(signIn)

                        Button(action: signIn) {
                            Label {
                                Text(L10n.signInWithDatabricks)
                            } icon: {
                                Image.databricksLogo.resizable().scaledToFit().frame(width: 16, height: 16)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.dahlia(.primary))
                        .disabled(workspaceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    if showsLocalAccount {
                        ZStack {
                            Divider()
                            Text(L10n.orContinueWithoutSigningIn)
                                .font(.dahliaSecondary)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal)
                                .background(.background)
                        }

                        Button(action: onContinueLocally) {
                            Text(L10n.continueWithLocalAccount)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4)
                        }
                        .buttonStyle(.dahlia())
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 440, maxHeight: .infinity)
            .frame(width: 500, height: showsLocalAccount ? 420 : 340)
            .overlay(alignment: .topTrailing) {
                if !isEmbedded {
                    Button(L10n.close, systemImage: "xmark", action: cancel)
                        .labelStyle(.iconOnly)
                        .dahliaFixedSymbol()
                        .buttonStyle(.plain)
                        .frame(width: 28, height: 28)
                        .contentShape(.rect)
                        .background(
                            isCloseHovered ? DahliaDesign.contentHighlightColor : .clear,
                            in: .rect(cornerRadius: DahliaDesign.Highlight.regularCornerRadius)
                        )
                        .onHover { isCloseHovered = $0 }
                        .keyboardShortcut(.cancelAction)
                        .help(L10n.close)
                        .padding(12)
                }
            }
            .dahliaModalSurface(isEmbedded: isEmbedded)
        }
        .transition(.identity)
    }

    private func signIn() {
        guard signInTask == nil, !controller.isBusy, !workspaceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        signInTask = Task {
            defer { signInTask = nil }
            guard let id = await controller.signIn(workspaceURL: workspaceURL), !Task.isCancelled else { return }
            if controller.isNewAccount {
                await workspaceManagementModel.loadWorkspaces()
                guard !Task.isCancelled else { return }
                pendingConnectionID = id
            } else {
                completeSignIn(id)
            }
        }
    }

    private func transfer(_ workspace: WorkspaceRecord, to connectionID: UUID) {
        guard canTransferWorkspace, !isTransferringWorkspace else { return }
        isTransferringWorkspace = true
        transferError = nil
        signInTask = Task {
            defer {
                isTransferringWorkspace = false
                signInTask = nil
            }
            guard await workspaceManagementModel.moveWorkspace(workspace, toDatabricks: connectionID) else {
                workspaceManagementModel.isShowingError = false
                transferError = L10n.workspaceOperationFailed
                return
            }
            completeSignIn(connectionID)
        }
    }

    private func completeSignIn(_ connectionID: UUID) {
        onInteractionStateChange(false)
        onContinueWithDatabricks(connectionID)
    }

    /// Closing the modal also stops a pending browser sign-in, like its Cancel button.
    private func cancel() {
        guard !isTransferringWorkspace else { return }
        signInTask?.cancel()
        pendingConnectionID = nil
        onCancel()
    }
}
