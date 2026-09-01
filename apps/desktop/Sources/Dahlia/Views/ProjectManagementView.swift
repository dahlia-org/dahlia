import SwiftUI

struct ProjectManagementView: View {
    @Binding var isSidebarVisible: Bool
    var sidebarViewModel: SidebarViewModel
    @ObservedObject var captionViewModel: CaptionViewModel
    var updateController: AppUpdateController
    let recordingCoordinator: RecordingCoordinator
    @Bindable var mainWindowNavigation: MainWindowNavigation
    let appDatabase: AppDatabaseManager?
    var vaultManagementModel: VaultManagementModel
    let onShowUpcomingSchedule: () -> Void
    let onShowChat: () -> Void
    let onShowUnprocessedRecordings: () -> Void
    let showsCustomerIntelligence: Bool
    let onOpenCustomerIntelligence: () -> Void
    let onCreateProject: () -> Void
    let onOpenProject: (UUID) -> Void
    let onOpenMeeting: (UUID) -> Void
    let onShowProjectCatalog: () -> Void
    let onEditProject: (ProjectOverviewItem) -> Void
    let onRequestProjectDeletion: (ProjectOverviewItem) -> Void
    let onOpenSidebarProject: (UUID, ProjectNavigationIntent) -> Void
    let onSelectVault: (VaultRecord) -> Void

    var body: some View {
        let isShowingSettings = mainWindowNavigation.isShowingSettings

        MainSidebarSplitView(
            width: mainWindowNavigation.sidebarWidth,
            isVisible: isSidebarVisible || isShowingSettings,
            onWidthChange: mainWindowNavigation.updateSidebarWidth
        ) {
            MainWindowPaneContent(
                isShowingSettings: isShowingSettings,
                settingsBackground: .sidebar
            ) {
                MeetingListSidebarView(
                    viewModel: captionViewModel,
                    updateController: updateController,
                    sidebarViewModel: sidebarViewModel,
                    mainWindowNavigation: mainWindowNavigation,
                    recordingCoordinator: recordingCoordinator,
                    isShowingUpcomingSchedule: false,
                    onShowUpcomingSchedule: onShowUpcomingSchedule,
                    isShowingChat: false,
                    onShowChat: onShowChat,
                    isShowingProjects: true,
                    onShowProjects: onShowProjectCatalog,
                    isShowingUnprocessedRecordings: false,
                    onShowUnprocessedRecordings: onShowUnprocessedRecordings,
                    showsCustomerIntelligence: showsCustomerIntelligence,
                    onOpenCustomerIntelligence: onOpenCustomerIntelligence,
                    onCreateProject: onCreateProject,
                    onOpenProject: onOpenSidebarProject,
                    onSelectVault: onSelectVault
                )
            } settingsContent: {
                SettingsSidebarView(
                    selection: $mainWindowNavigation.settingsCategory,
                    vaults: vaultManagementModel.vaults,
                    currentVault: sidebarViewModel.currentVault,
                    updateController: updateController,
                    onSelectVault: onSelectVault,
                    onReturnToApp: mainWindowNavigation.dismissSettings
                )
            }
        } detail: {
            MainWindowPaneContent(isShowingSettings: isShowingSettings) {
                projectCatalog
            } settingsContent: {
                SettingsDetailView(
                    selection: $mainWindowNavigation.settingsCategory,
                    captionViewModel: captionViewModel,
                    sidebarViewModel: sidebarViewModel,
                    appDatabase: appDatabase,
                    vaultManagementModel: vaultManagementModel,
                    onShowUnprocessedRecordings: openUnprocessedRecordingsFromSettings
                )
            }
            .mainDetailPane()
        }
        .onChange(of: sidebarViewModel.allProjectItems) {
            reconcileVisibleProject()
        }
    }

    private func openUnprocessedRecordingsFromSettings(vaultID: UUID) {
        if sidebarViewModel.currentVault?.id != vaultID {
            guard let vault = vaultManagementModel.vaults.first(where: { $0.id == vaultID }) else { return }
            onSelectVault(vault)
            guard sidebarViewModel.currentVault?.id == vaultID else { return }
        }
        onShowUnprocessedRecordings()
        mainWindowNavigation.openUnprocessedRecordingsFromSettings()
    }

    @ViewBuilder
    private var projectCatalog: some View {
        if AppSettings.shared.currentVault == nil {
            ContentUnavailableView {
                Label(L10n.noVaultSelected, systemImage: "externaldrive")
            } description: {
                Text(L10n.projectManagementNoVaultDescription)
            }
        } else if !sidebarViewModel.isProjectCatalogLoaded {
            ProgressView(L10n.loadingProjects)
        } else if sidebarViewModel.projectCatalogLoadFailed {
            ContentUnavailableView {
                Label(L10n.projectCatalogLoadFailed, systemImage: "exclamationmark.triangle")
            } description: {
                Text(L10n.projectCatalogLoadFailedDescription)
            } actions: {
                Button(L10n.retry, action: sidebarViewModel.retryProjectCatalogLoading)
            }
        } else if case let .project(projectID) = mainWindowNavigation.currentLocation,
                  let project = sidebarViewModel.allProjectItems.first(where: { $0.projectId == projectID }) {
            ProjectDetailView(
                project: project,
                projects: sidebarViewModel.allProjectItems,
                appearance: projectAppearance(project.projectId),
                appearanceForProject: projectAppearance,
                vaultID: sidebarViewModel.currentVault?.id,
                dbQueue: sidebarViewModel.dbQueue,
                workspaceChangeToken: sidebarViewModel.workspaceChangeToken,
                displayMode: mainWindowNavigation.projectDetailDisplayMode(vaultId: sidebarViewModel.currentVault?.id),
                onChangeDisplayMode: {
                    mainWindowNavigation.setProjectDetailDisplayMode($0, vaultId: sidebarViewModel.currentVault?.id)
                },
                onBack: onShowProjectCatalog,
                onEdit: { onEditProject(project) },
                onOpenMeeting: onOpenMeeting
            )
        } else {
            ProjectCatalogView(
                projects: sidebarViewModel.allProjectItems,
                pinnedProjectIDs: Set(mainWindowNavigation.pinnedProjectIDs(vaultId: sidebarViewModel.currentVault?.id)),
                canCreateMeeting: !captionViewModel.isRecordingStartPending && !captionViewModel.isFinalizingRecording,
                appearanceForProject: projectAppearance,
                onOpenProject: { onOpenProject($0.projectId) },
                onEditProject: onEditProject,
                onDeleteProject: onRequestProjectDeletion,
                onTogglePin: toggleProjectPin,
                onCreateMeeting: recordingCoordinator.createDraftMeeting,
                onCreateProject: onCreateProject
            )
        }
    }

    private func reconcileVisibleProject() {
        guard case let .project(projectID) = mainWindowNavigation.currentLocation,
              !sidebarViewModel.allProjectItems.contains(where: { $0.projectId == projectID }) else { return }
        onShowProjectCatalog()
    }

    private func toggleProjectPin(_ project: ProjectOverviewItem) {
        mainWindowNavigation.toggleProjectPin(project.projectId, vaultId: sidebarViewModel.currentVault?.id)
    }

    private func projectAppearance(_ projectId: UUID) -> ProjectAppearance {
        mainWindowNavigation.projectAppearance(
            for: projectId,
            in: sidebarViewModel.projectItemsByID,
            vaultId: sidebarViewModel.currentVault?.id
        )
    }
}
