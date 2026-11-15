import SwiftUI

struct WorkspaceDeletionDialog: View {
    let workspace: WorkspaceRecord
    let destinations: [WorkspaceRecord]
    let onCancel: () -> Void
    let onConfirm: (UUID?) async -> Bool

    @State private var transfersContent = true
    @State private var destinationID: UUID?
    @State private var isDeleting = false
    @State private var deletionFailed = false

    var body: some View {
        ZStack {
            Button(action: cancel) {
                Color.black.opacity(0.16).ignoresSafeArea()
            }
            .buttonStyle(.plain)
            .focusable(false)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 20) {
                ProjectEditorSheetHeader(
                    title: L10n.removeWorkspaceConfirmation(workspace.name),
                    isDisabled: isDeleting,
                    onClose: cancel
                )
                Form {
                    Section {
                        Picker(L10n.workspaceContentHandling, selection: $transfersContent) {
                            Text(L10n.transferWorkspaceContent).font(.dahliaBody).tag(true)
                            Text(L10n.deleteWorkspaceContent).font(.dahliaBody).tag(false)
                        }
                        .pickerStyle(.radioGroup)
                        if transfersContent {
                            Picker(L10n.workspaceTransferDestination, selection: $destinationID) {
                                Text(L10n.selectWorkspaceTransferDestination).font(.dahliaBody).tag(nil as UUID?)
                                ForEach(destinations) { destination in
                                    Text(destination.name).font(.dahliaBody).tag(destination.id as UUID?)
                                }
                            }
                            Text(destinations.isEmpty ? L10n.noWorkspaceTransferDestination : L10n.workspaceTransferDescription)
                                .foregroundStyle(.secondary)
                        } else {
                            Text(L10n.removeWorkspaceConfirmationDescription)
                                .foregroundStyle(.red)
                        }
                        Text(L10n.workspaceExportFilesAreKept)
                            .foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
                .disabled(isDeleting)

                if deletionFailed {
                    Text(L10n.workspaceRemoveFailed).foregroundStyle(.red)
                }

                HStack {
                    Spacer()
                    Button(L10n.cancel, role: .cancel, action: cancel)
                        .buttonStyle(.bordered)
                        .keyboardShortcut(.cancelAction)
                        .disabled(isDeleting)
                    Button(role: .destructive, action: confirm) {
                        HStack {
                            if isDeleting { ProgressView().controlSize(.small) }
                            Text(isDeleting ? L10n.removingWorkspace : transfersContent ? L10n.transferAndDeleteWorkspace : L10n.removeWorkspace)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(isDeleting || transfersContent && !destinations.contains(where: { $0.id == destinationID }))
                }
            }
            .font(.dahliaBody)
            .padding(24)
            .frame(width: 560, height: 440)
            .dahliaModalSurface()
        }
    }

    private func cancel() {
        guard !isDeleting else { return }
        onCancel()
    }

    private func confirm() {
        isDeleting = true
        deletionFailed = false
        Task {
            if await onConfirm(transfersContent ? destinationID : nil) {
                onCancel()
            } else {
                deletionFailed = true
                isDeleting = false
            }
        }
    }
}
