import SwiftUI

struct WorkspaceSettingsView: View {
    let appDatabase: AppDatabaseManager?
    var model: WorkspaceManagementModel
    let currentWorkspace: WorkspaceRecord?
    let onShowDetails: (UUID) -> Void
    let onRequestDeletion: (WorkspaceRecord) -> Void
    let onUpdateWorkspace: (WorkspaceRecord) -> Void

    @ObservedObject private var settings = AppSettings.shared

    @State private var isShowingFolderPicker = false
    @State private var isShowingCreateAlert = false
    @State private var isShowingRenameAlert = false
    @State private var pendingRename: WorkspaceRecord?
    @State private var pendingExportFolderWorkspace: WorkspaceRecord?
    @State private var proposedName = ""

    var body: some View {
        Form {
            sections
        }
        .formStyle(.grouped)
        .font(.dahliaBody)
        .disabled(
            model.isRemovingWorkspace || model.isRenamingWorkspace
        )
        .overlay {
            if model.isRemovingWorkspace {
                ProgressView(L10n.removingWorkspace)
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
    }

    @ViewBuilder
    private var sections: some View {
        if model.isLoading, model.workspaces.isEmpty {
            Section { ProgressView(L10n.loadingWorkspaces) }
        }

        Section {
            ForEach(model.workspaces.sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }) { workspace in
                workspaceRow(workspace)
            }
            if model.workspaces.isEmpty {
                Text(L10n.noWorkspaces)
                    .foregroundStyle(DahliaDesign.secondaryTextColor)
            }
        } header: {
            HStack(spacing: 8) {
                Image(systemName: "desktopcomputer")
                    .accessibilityHidden(true)
                Text(L10n.thisMac)
                    .font(.dahliaSectionHeader)
                Button {
                    showCreateAlert()
                } label: {
                    Label(L10n.addWorkspace, systemImage: "plus")
                        .labelStyle(.iconOnly)
                        .padding(4)
                        .contentShape(.rect)
                }
                .buttonStyle(WorkspaceSettingsButtonStyle())
                .help(L10n.addWorkspace)
                Spacer(minLength: 0)
            }
        }
        if !model.workspaces.isEmpty {
            Section {} footer: {
                Text(L10n.settingsOutputLanguageDescription)
            }
        }
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

            Button {
                onShowDetails(workspace.id)
            } label: {
                Text(workspace.name)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .contentShape(.rect)
            }
            .buttonStyle(WorkspaceSettingsButtonStyle())
            .foregroundStyle(.primary)
            .help(L10n.workspaceDetails)

            Spacer(minLength: 12)

            HStack {
                Picker(L10n.summaryOutputLanguage, selection: outputLanguageBinding(for: workspace)) {
                    ForEach(SummaryLanguage.allCases) { Text($0.displayName).font(.dahliaBody).tag($0) }
                }
                .labelsHidden()
                .disabled(model.isUpdatingOutputLanguage)
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
            Button(L10n.rename, systemImage: "pencil", action: { requestRename(workspace) })

            Divider()

            Menu(L10n.localExportFolder, systemImage: "folder") {
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
            }

            Divider()
            Button(L10n.workspaceDetails, systemImage: "info.circle") { onShowDetails(workspace.id) }

            if workspace.id != currentWorkspace?.id {
                Button(L10n.removeWorkspace, systemImage: "trash", role: .destructive) {
                    onRequestDeletion(workspace)
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

}
