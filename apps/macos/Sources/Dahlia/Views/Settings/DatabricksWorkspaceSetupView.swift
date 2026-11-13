import SwiftUI

struct DatabricksWorkspaceSetupView: View {
    let workspaces: [WorkspaceRecord]
    let isEmbedded: Bool
    let isBusy: Bool
    let canTransferWorkspace: Bool
    let errorMessage: String?
    let onCancel: () -> Void
    let onCreate: () -> Void
    let onTransfer: (WorkspaceRecord) -> Void

    @State private var selectedWorkspaceID: UUID?

    var body: some View {
        ZStack {
            if !isEmbedded {
                Color.black.opacity(0.16)
                    .ignoresSafeArea()
                    .contentShape(.rect)
            }

            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.accountWorkspaceSetupTitle)
                        .font(.dahliaTitle2)
                        .accessibilityAddTraits(.isHeader)
                    Text(L10n.accountWorkspaceSetupPrompt)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.workspace)
                            .font(.dahliaHeadline)
                        Menu {
                            Picker(L10n.workspace, selection: $selectedWorkspaceID) {
                                Text(L10n.accountWorkspaceCreateOption).font(.dahliaBody).tag(UUID?.none)
                                if !workspaces.isEmpty {
                                    Section(L10n.accountWorkspaceTransfer) {
                                        ForEach(workspaces) { workspace in
                                            Text(workspaceTitle(workspace)).font(.dahliaBody).tag(Optional(workspace.id))
                                        }
                                    }
                                }
                            }
                        } label: {
                            HStack {
                                Text(selectedWorkspaceTitle)
                                    .lineLimit(1)
                                Spacer()
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.dahliaSecondary)
                            }
                            .frame(maxWidth: .infinity)
                            .contentShape(.rect)
                        }
                        .menuIndicator(.hidden)
                        .buttonStyle(.dahlia())
                        .accessibilityLabel(L10n.workspace)
                        .accessibilityValue(selectedWorkspaceTitle)
                        .disabled(isBusy)
                    }

                    Text(selectedWorkspaceID == nil ? L10n.accountWorkspaceCreateDescription : L10n.accountWorkspaceSetupDescription)
                        .font(.dahliaSecondary)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if selectedWorkspaceID != nil, !canTransferWorkspace {
                        SettingsStatusMessage(
                            text: L10n.accountWorkspaceTransferUnavailable,
                            systemImage: "exclamationmark.triangle",
                            tint: .orange
                        )
                    }
                    if let errorMessage {
                        SettingsStatusMessage(text: errorMessage, systemImage: "exclamationmark.triangle.fill", tint: .red)
                    }
                }

                HStack(spacing: 12) {
                    if isBusy { ProgressView().controlSize(.small) }
                    Spacer()
                    Button(L10n.cancel, action: onCancel)
                        .buttonStyle(.dahlia())
                        .keyboardShortcut(.cancelAction)
                    Button(selectedWorkspaceID == nil ? L10n.accountWorkspaceCreate : L10n.accountWorkspaceTransfer, action: confirm)
                        .buttonStyle(.dahlia(.primary))
                        .keyboardShortcut(.defaultAction)
                        .disabled(selectedWorkspaceID != nil && !canTransferWorkspace)
                }
                .disabled(isBusy)
            }
            .font(.dahliaBody)
            .padding(28)
            .frame(width: 500)
            .dahliaModalSurface(isEmbedded: isEmbedded)
        }
    }

    private var selectedWorkspaceTitle: String {
        workspaces.first(where: { $0.id == selectedWorkspaceID }).map(workspaceTitle) ?? L10n.accountWorkspaceCreateOption
    }

    private func confirm() {
        guard !isBusy else { return }
        if let selectedWorkspaceID {
            guard canTransferWorkspace,
                  let workspace = workspaces.first(where: { $0.id == selectedWorkspaceID }) else { return }
            onTransfer(workspace)
        } else {
            onCreate()
        }
    }

    private func workspaceTitle(_ workspace: WorkspaceRecord) -> String {
        let account = workspace.databricksConnectionId.flatMap { id in
            WorkspaceAISettingsModel.shared.databricksConnections.first { $0.id == id }
        }
        let accountName = workspace.databricksConnectionId == nil
            ? L10n.localAccount
            : account.map { L10n.unityGatewayHost($0.hostName) } ?? L10n.databricks
        return "\(workspace.name) · \(accountName)"
    }
}
