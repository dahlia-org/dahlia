import SwiftUI

struct WorkspaceDetailView: View {
    let workspace: WorkspaceRecord?
    let hasRegisteredWorkspaces: Bool
    let isCurrentWorkspace: Bool
    let canSwitchWorkspace: Bool
    let onOpen: () -> Void
    let onAdd: () -> Void

    var body: some View {
        if let workspace {
            Form {
                Section(L10n.workspaceDetails) {
                    LabeledContent(L10n.workspaceName, value: workspace.name)
                    LabeledContent(L10n.location) {
                        Text(workspace.path ?? L10n.noLocalExportFolder)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }

                    if isCurrentWorkspace {
                        LabeledContent {
                            Label(L10n.currentWorkspace, systemImage: "checkmark.circle.fill")
                                .foregroundStyle(DahliaDesign.secondaryTextColor)
                        } label: {
                            Text(L10n.status)
                            Text(L10n.currentWorkspaceRemoveDescription)
                        }
                    }
                }

                Section {
                    Button(L10n.openWorkspace, systemImage: "folder", action: onOpen)
                        .buttonStyle(.borderedProminent)
                        .disabled(isCurrentWorkspace || !canSwitchWorkspace)
                } footer: {
                    Text(L10n.openWorkspaceDescription)
                }
            }
            .formStyle(.grouped)
        } else if hasRegisteredWorkspaces {
            ContentUnavailableView {
                Label(L10n.noWorkspaceSelected, systemImage: "externaldrive")
            } description: {
                Text(L10n.selectWorkspaceDescription)
            }
        } else {
            ContentUnavailableView {
                Label(L10n.noWorkspaces, systemImage: "externaldrive.badge.plus")
            } description: {
                Text(L10n.noWorkspacesDescription)
            } actions: {
                Button(L10n.openFolderAsWorkspace, systemImage: "folder.badge.plus", action: onAdd)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}
