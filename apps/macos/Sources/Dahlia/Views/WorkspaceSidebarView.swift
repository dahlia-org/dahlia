import SwiftUI

struct WorkspaceSidebarView: View {
    let workspaces: [WorkspaceRecord]
    @Binding var selectedWorkspaceId: UUID?
    let currentWorkspaceId: UUID?
    var updateController: AppUpdateController
    let onAdd: () -> Void
    let onRemove: (WorkspaceRecord) -> Void

    @Environment(MainWindowNavigation.self) private var mainWindowNavigation

    private var selectedWorkspace: WorkspaceRecord? {
        guard let selectedWorkspaceId else { return nil }
        return workspaces.first(where: { $0.id == selectedWorkspaceId })
    }

    var body: some View {
        VStack(spacing: 0) {
            DahliaWindowHeader(reservesWindowControls: true) {
                Text(L10n.workspace)
                    .font(.dahliaHeadline)
                    .lineLimit(1)

                Spacer(minLength: 0)

                if updateController.isUpdateAvailable {
                    DahliaWindowHeaderIconButton(
                        label: updateButtonLabel,
                        systemImage: "arrow.down.circle.fill",
                        action: updateController.showUpdateDialog
                    )
                }

                DahliaWindowHeaderIconButton(
                    label: L10n.addWorkspace,
                    systemImage: "plus",
                    action: onAdd
                )
                .disabled(mainWindowNavigation.isShowingSettings)

                DahliaWindowHeaderIconButton(
                    label: removeButtonLabel,
                    systemImage: "trash",
                    action: requestRemoval
                )
                .disabled(
                    mainWindowNavigation.isShowingSettings
                        || selectedWorkspace == nil
                        || isCurrentWorkspaceSelected
                        || selectedWorkspace?.accountConnectionId != nil
                )
            }

            List(selection: $selectedWorkspaceId) {
                ForEach(workspaces) { workspace in
                    HStack {
                        Label {
                            VStack(alignment: .leading) {
                                Text(workspace.name)
                                Text(workspace.path ?? L10n.noLocalExportFolder)
                                    .font(.dahliaSecondary)
                                    .foregroundStyle(DahliaDesign.secondaryTextColor)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        } icon: {
                            WorkspaceIcon(workspace: workspace)
                        }

                        Spacer()

                        if workspace.id == currentWorkspaceId {
                            Image(systemName: "checkmark.circle.fill")
                                .dahliaFixedSymbol()
                                .foregroundStyle(DahliaDesign.secondaryTextColor)
                                .accessibilityLabel(L10n.currentWorkspace)
                        }
                    }
                    .modifier(SidebarNavigationRowModifier(isSelected: selectedWorkspaceId == workspace.id))
                    .tag(workspace.id)
                }
            }
            .listStyle(.sidebar)
            .onDeleteCommand(perform: requestRemoval)
        }
    }

    private var removeButtonLabel: String {
        isCurrentWorkspaceSelected ? L10n.currentWorkspaceRemoveDescription : L10n.removeWorkspace
    }

    private var isCurrentWorkspaceSelected: Bool {
        selectedWorkspace?.id == currentWorkspaceId
    }

    private var updateButtonLabel: String {
        guard let version = updateController.availableVersion else {
            return L10n.updateAvailable
        }
        return L10n.updateAvailableVersion(version)
    }

    private func requestRemoval() {
        guard let selectedWorkspace, !isCurrentWorkspaceSelected, selectedWorkspace.accountConnectionId == nil else { return }
        onRemove(selectedWorkspace)
    }
}
