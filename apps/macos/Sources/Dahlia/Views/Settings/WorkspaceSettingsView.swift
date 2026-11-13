import SwiftUI

struct WorkspaceSettingsView: View {
    let appDatabase: AppDatabaseManager?
    var model: WorkspaceManagementModel
    let currentWorkspace: WorkspaceRecord?
    let accountConnections: [DahliaAccountConnection]
    let canSwitchWorkspace: Bool
    let onUpdateWorkspace: (WorkspaceRecord) -> Void

    @State private var isShowingFolderPicker = false
    @State private var isShowingCreateAlert = false
    @State private var isShowingRenameAlert = false
    @State private var publishingDocuments: WorkspaceRecord?
    @State private var pendingRemoval: WorkspaceRecord?
    @State private var pendingRename: WorkspaceRecord?
    @State private var pendingExportFolderWorkspace: WorkspaceRecord?
    @State private var proposedName = ""

    var body: some View {
        sections
            .disabled(
                model.isRemovingWorkspace || model.isRenamingWorkspace
                    || model.updatingWorkspaceAccountID != nil
            )
            .overlay {
                if model.isRemovingWorkspace {
                    ProgressView(L10n.removingWorkspace)
                }
            }
            .overlay {
                if let workspace = publishingDocuments, let appDatabase {
                    DocumentPublicationView(workspace: workspace, dbQueue: appDatabase.dbQueue) { publishingDocuments = nil }
                }
            }
            .onChange(of: currentWorkspace?.id) {
                if pendingRemoval?.id == currentWorkspace?.id {
                    pendingRemoval = nil
                }
            }
            .task(id: appDatabase != nil) {
                await model.configure(appDatabase: appDatabase)
            }
            .fileImporter(
                isPresented: $isShowingFolderPicker,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false,
                onCompletion: handleFolderImport
            )
            .fileDialogDefaultDirectory(WorkspaceManagementModel.defaultWorkspaceURL)
            .alert(
                pendingRename.map { L10n.renameWorkspace($0.name) } ?? L10n.rename,
                isPresented: $isShowingRenameAlert
            ) {
                TextField(L10n.workspaceName, text: $proposedName)
                Button(L10n.save, action: renameWorkspace)
                    .disabled(proposedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button(L10n.cancel, role: .cancel, action: clearRenameRequest)
            }
            .alert(L10n.createNewWorkspace, isPresented: $isShowingCreateAlert) {
                TextField(L10n.workspaceName, text: $proposedName)
                Button(L10n.create, action: createWorkspace)
                    .disabled(proposedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button(L10n.cancel, role: .cancel, action: clearCreateRequest)
            } message: {
                Text(L10n.workspaceNameDescription)
            }
            .confirmationDialog(
                pendingRemoval.map { L10n.removeWorkspaceConfirmation($0.name) } ?? "",
                isPresented: Binding(
                    get: { pendingRemoval != nil },
                    set: { if !$0 { pendingRemoval = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let workspace = pendingRemoval {
                    Button(L10n.removeWorkspace, role: .destructive) {
                        removeWorkspace(workspace)
                    }
                }
                Button(L10n.cancel, role: .cancel) {}
            } message: {
                Text(L10n.removeWorkspaceConfirmationDescription)
            }
    }

    private var sections: some View {
        Section {
            if model.isLoading, model.workspaces.isEmpty {
                ProgressView(L10n.loadingWorkspaces)
            } else if workspacesInCreationOrder.isEmpty {
                Label(L10n.noWorkspaces, systemImage: ProjectIcon.workspace.systemImageName)
                    .foregroundStyle(DahliaDesign.secondaryTextColor)
            } else {
                ForEach(workspacesInCreationOrder) { workspace in
                    workspaceRow(workspace)
                }
            }
        } header: {
            HStack {
                Text(L10n.workspace)
                    .font(.dahliaSectionHeader)

                Spacer()

                Button(L10n.addWorkspace, systemImage: "plus", action: showCreateAlert)
                    .buttonStyle(.dahlia(.primary))
                    .controlSize(.small)
                    .help(L10n.workspaceNameDescription)
            }
        } footer: {
            if workspacesInCreationOrder.isEmpty, !model.isLoading {
                Text(L10n.noWorkspacesDescription)
            } else {
                Text(L10n.settingsOutputLanguageDescription)
            }
        }
    }

    private var workspacesInCreationOrder: [WorkspaceRecord] {
        model.workspaces.sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
    }

    private func workspaceRow(_ workspace: WorkspaceRecord) -> some View {
        HStack(spacing: 0) {
            WorkspaceAppearanceButton(workspace: workspace) { appearance in
                guard let updated = await model.renameWorkspace(workspace, to: workspace.name, appearance: appearance)
                else { return false }
                if currentWorkspace?.id == updated.id { onUpdateWorkspace(updated) }
                return true
            }
            .padding(.leading, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(workspace.name)
                Text(workspace.path ?? L10n.noLocalExportFolder)
                    .font(.dahliaSecondary)
                    .foregroundStyle(DahliaDesign.secondaryTextColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .help(workspace.path ?? L10n.noLocalExportFolder)

            HStack {
                WorkspaceAccountPicker(
                    workspace: workspace,
                    connections: accountConnections,
                    databricksAccounts: WorkspaceAISettingsModel.shared.databricksConnections,
                    onSelect: { await changeAccount(of: workspace, to: $0) }
                )
                // A recording keeps the account it started with until it is processed.
                .disabled(workspace.accountConnectionId != nil || !canSwitchWorkspace)
                if workspace.syncRecoveryState == "updateRequired" {
                    Label(L10n.workspaceSyncUpdateRequired, systemImage: "exclamationmark.triangle")
                        .font(.dahliaSecondary).foregroundStyle(.orange)
                } else if model.blockedSyncWorkspaceIDs.contains(workspace.id) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help(L10n.workspaceSyncConflict)
                        .accessibilityLabel(L10n.workspaceSyncConflict)
                } else if workspace.syncRecoveryState != nil {
                    Label(
                        workspace.syncRecoveryState == "recovering" ? L10n.workspaceSyncRecovering : L10n.workspaceSyncRecoveryPending,
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                    .font(.dahliaSecondary).foregroundStyle(.secondary)
                }
                Picker(L10n.summaryOutputLanguage, selection: outputLanguageBinding(for: workspace)) {
                    ForEach(SummaryLanguage.allCases) { Text($0.displayName).font(.dahliaBody).tag($0) }
                }
                .disabled(!workspace.allowsWorkspaceManagement || model.isUpdatingOutputLanguage)
                workspaceActions(for: workspace)
            }
            .padding(.trailing, 8)
            .padding(.vertical, 6)
        }
    }

    private func outputLanguageBinding(for workspace: WorkspaceRecord) -> Binding<SummaryLanguage> {
        Binding(
            get: { workspace.generationSettings.outputLanguage },
            set: { language in
                Task {
                    if let updated = await model.setOutputLanguage(for: workspace, to: language) {
                        onUpdateWorkspace(updated)
                    }
                }
            }
        )
    }

    private func showCreateAlert() {
        proposedName = ""
        isShowingCreateAlert = true
    }

    private func workspaceActions(for workspace: WorkspaceRecord) -> some View {
        Menu(L10n.actions, systemImage: "ellipsis.circle") {
            if workspace.allowsWorkspaceManagement {
                Button(L10n.rename, systemImage: "pencil", action: { requestRename(workspace) })
            }

            Button(workspace.path == nil ? L10n.setLocalExportFolder : L10n.changeLocalExportFolder, systemImage: "folder") {
                pendingExportFolderWorkspace = workspace
                isShowingFolderPicker = true
            }
            if workspace.path != nil {
                Button(L10n.removeLocalExportFolder, systemImage: "folder.badge.minus") {
                    Task {
                        if let updated = await model.setExportFolder(for: workspace, to: nil) {
                            onUpdateWorkspace(updated)
                        }
                    }
                }
            }

            Button(L10n.documentPrivateLegacy) { publishingDocuments = workspace }

            if workspace.id != currentWorkspace?.id, workspace.accountConnectionId == nil {
                Button(L10n.removeWorkspace, systemImage: "minus", role: .destructive) {
                    pendingRemoval = workspace
                }
            }
        }
        .labelStyle(.iconOnly)
        .dahliaFixedSymbol()
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help(L10n.actions)
    }

    private func handleFolderImport(_ result: Result<[URL], any Error>) {
        switch result {
        case let .success(urls):
            guard let url = urls.first else { return }
            Task {
                if let workspace = pendingExportFolderWorkspace,
                   let updated = await model.setExportFolder(for: workspace, to: url) {
                    onUpdateWorkspace(updated)
                }
                pendingExportFolderWorkspace = nil
            }
        case let .failure(error):
            guard (error as? CocoaError)?.code != .userCancelled else { return }
            pendingExportFolderWorkspace = nil
            model.presentFolderSelectionError(error)
        }
    }

    private func createWorkspace() {
        let name = proposedName
        clearCreateRequest()
        Task { _ = await model.createWorkspace(named: name) }
    }

    private func clearCreateRequest() {
        proposedName = ""
    }

    private func requestRename(_ workspace: WorkspaceRecord) {
        guard workspace.allowsWorkspaceManagement else { return }
        pendingRename = workspace
        proposedName = workspace.name
        isShowingRenameAlert = true
    }

    private func renameWorkspace() {
        guard let workspace = pendingRename else { return }
        let name = proposedName
        clearRenameRequest()
        Task {
            if let renamedWorkspace = await model.renameWorkspace(workspace, to: name) {
                onUpdateWorkspace(renamedWorkspace)
            }
        }
    }

    private func clearRenameRequest() {
        pendingRename = nil
        proposedName = ""
    }

    private func removeWorkspace(_ workspace: WorkspaceRecord) {
        Task {
            _ = await model.removeWorkspace(workspace, currentWorkspaceId: currentWorkspace?.id)
            pendingRemoval = nil
        }
    }

    private func changeAccount(of workspace: WorkspaceRecord, to choice: WorkspaceAccountChoice) async -> WorkspaceAccountChoice {
        switch choice {
        case .local:
            return await model.moveWorkspace(workspace, toDatabricks: nil) ? choice : WorkspaceAccountChoice(workspace)
        case let .databricks(connectionID):
            return await model.moveWorkspace(workspace, toDatabricks: connectionID) ? choice : WorkspaceAccountChoice(workspace)
        case let .dahlia(connectionID):
            if let connection = accountConnections.first(where: { $0.id == connectionID }) {
                await model.requestServerAdoption(for: workspace, connection: connection)
            }
            return WorkspaceAccountChoice(workspace)
        }
    }
}
