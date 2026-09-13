import SwiftUI

/// ワークスペースの登録・選択・登録解除を行う画面。
struct WorkspacePickerView: View {
    private enum SidebarMetrics {
        static let minimumWidth: CGFloat = 220
        static let defaultWidth: CGFloat = 280
        static let maximumWidth: CGFloat = 360
    }

    let appDatabase: AppDatabaseManager?
    var model: WorkspaceManagementModel
    let canSwitchWorkspace: Bool
    @ObservedObject var captionViewModel: CaptionViewModel
    var sidebarViewModel: SidebarViewModel
    @Bindable var mainWindowNavigation: MainWindowNavigation
    var updateController: AppUpdateController
    let onWorkspaceSelected: (WorkspaceRecord) -> Void

    @ObservedObject private var settings = AppSettings.shared
    @State private var selectedWorkspaceId: UUID?
    @State private var isShowingFolderPicker = false
    @State private var workspaceSidebarWidth = SidebarMetrics.defaultWidth

    private var selectedWorkspace: WorkspaceRecord? {
        guard let selectedWorkspaceId else { return nil }
        return model.workspaces.first(where: { $0.id == selectedWorkspaceId })
    }

    var body: some View {
        let isShowingSettings = mainWindowNavigation.isShowingSettings
        let sidebarWidth = isShowingSettings ? mainWindowNavigation.sidebarWidth : workspaceSidebarWidth
        let minimumSidebarWidth = isShowingSettings ? MainSidebarLayout.minimumWidth : SidebarMetrics.minimumWidth
        let maximumSidebarWidth = isShowingSettings ? MainSidebarLayout.maximumWidth : SidebarMetrics.maximumWidth

        HSplitView {
            MainWindowPaneContent(
                isShowingSettings: isShowingSettings,
                settingsBackground: .sidebar
            ) {
                WorkspaceSidebarView(
                    workspaces: model.workspaces,
                    selectedWorkspaceId: $selectedWorkspaceId,
                    currentWorkspaceId: settings.currentWorkspace?.id,
                    updateController: updateController,
                    onAdd: showFolderPicker,
                    onRemove: removeWorkspace
                )
                .disabled(model.isRemovingWorkspace)
            } settingsContent: {
                SettingsSidebarView(
                    selection: $mainWindowNavigation.settingsCategory,
                    workspaces: model.workspaces,
                    currentWorkspace: settings.currentWorkspace,
                    updateController: updateController,
                    onSelectWorkspace: onWorkspaceSelected,
                    onReturnToApp: mainWindowNavigation.dismissSettings
                )
            }
            .padding(.top, isShowingSettings ? DahliaDesign.windowHeaderHeight : 0)
            .mainSidebarPane(
                width: sidebarWidth,
                minimumWidth: minimumSidebarWidth,
                maximumWidth: maximumSidebarWidth,
                widthSourceID: isShowingSettings ? 1 : 0,
                onWidthChange: updateSidebarWidth
            )

            MainWindowPaneContent(isShowingSettings: isShowingSettings) {
                VStack(spacing: 0) {
                    DahliaWindowHeader {
                        Text(selectedWorkspace?.name ?? L10n.workspaceDetails)
                            .font(.headline)
                            .lineLimit(1)

                        Spacer(minLength: 12)
                    }

                    Group {
                        if model.isRemovingWorkspace {
                            ProgressView(L10n.removingWorkspace)
                        } else if model.isLoading, model.workspaces.isEmpty {
                            ProgressView(L10n.loadingWorkspaces)
                        } else {
                            WorkspaceDetailView(
                                workspace: selectedWorkspace,
                                hasRegisteredWorkspaces: !model.workspaces.isEmpty,
                                isCurrentWorkspace: selectedWorkspace?.id == settings.currentWorkspace?.id,
                                canSwitchWorkspace: canSwitchWorkspace,
                                onOpen: openSelectedWorkspace,
                                onAdd: showFolderPicker
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .disabled(model.isRemovingWorkspace)
            } settingsContent: {
                SettingsDetailView(
                    selection: $mainWindowNavigation.settingsCategory,
                    captionViewModel: captionViewModel,
                    sidebarViewModel: sidebarViewModel,
                    appDatabase: appDatabase,
                    workspaceManagementModel: model,
                    onShowUnprocessedRecordings: openUnprocessedRecordingsFromSettings
                )
            }
            .padding(.top, isShowingSettings ? DahliaDesign.windowHeaderHeight : 0)
            .mainDetailPane()
        }
        .overlay(alignment: .top) {
            if isShowingSettings {
                DahliaWindowHeader(reservesWindowControls: true, backgroundColor: .clear) {
                    Spacer()
                }
            }
        }
        .frame(minWidth: 720, minHeight: 460)
        .task(id: appDatabase != nil) {
            await model.configure(appDatabase: appDatabase)
            reconcileSelection()
        }
        .onChange(of: model.workspaces.map(\.id)) { reconcileSelection() }
        .fileImporter(
            isPresented: $isShowingFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false,
            onCompletion: handleFolderImport
        )
        .fileDialogDefaultDirectory(WorkspaceManagementModel.defaultWorkspaceURL)
    }

    private func showFolderPicker() {
        isShowingFolderPicker = true
    }

    private func openUnprocessedRecordingsFromSettings(workspaceID: UUID) {
        guard canSwitchWorkspace,
              let workspace = model.workspaces.first(where: { $0.id == workspaceID }) else { return }
        openWorkspace(workspace)
        guard sidebarViewModel.currentWorkspace?.id == workspaceID else { return }
        mainWindowNavigation.openUnprocessedRecordingsFromSettings()
    }

    private func updateSidebarWidth(_ width: CGFloat) {
        if mainWindowNavigation.isShowingSettings {
            mainWindowNavigation.updateSidebarWidth(width)
        } else {
            workspaceSidebarWidth = min(max(width, SidebarMetrics.minimumWidth), SidebarMetrics.maximumWidth)
        }
    }

    private func handleFolderImport(_ result: Result<[URL], any Error>) {
        switch result {
        case let .success(urls):
            guard let url = urls.first else { return }
            let isAccessing = url.startAccessingSecurityScopedResource()
            defer {
                if isAccessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            Task {
                guard let workspace = await model.registerWorkspace(at: url) else { return }
                selectedWorkspaceId = workspace.id
                openWorkspace(workspace)
            }
        case let .failure(error):
            guard (error as? CocoaError)?.code != .userCancelled else { return }
            model.presentFolderSelectionError(error)
        }
    }

    private func reconcileSelection() {
        let preferredIds = [selectedWorkspaceId, settings.currentWorkspace?.id].compactMap(\.self)
        selectedWorkspaceId = preferredIds.first(where: { id in
            model.workspaces.contains(where: { $0.id == id })
        }) ?? model.workspaces.first?.id
    }

    private func removeWorkspace(_ workspace: WorkspaceRecord) {
        Task {
            if await model.removeWorkspace(workspace, currentWorkspaceId: settings.currentWorkspace?.id), selectedWorkspaceId == workspace.id {
                selectedWorkspaceId = model.workspaces.first?.id
            }
        }
    }

    private func openSelectedWorkspace() {
        guard let selectedWorkspace else { return }
        openWorkspace(selectedWorkspace)
    }

    private func openWorkspace(_ workspace: WorkspaceRecord) {
        guard canSwitchWorkspace else { return }
        onWorkspaceSelected(workspace)
    }
}
