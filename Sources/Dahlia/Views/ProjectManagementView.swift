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
    let onShowUnprocessedRecordings: () -> Void
    let showsCustomerIntelligence: Bool
    let onOpenCustomerIntelligence: () -> Void
    let onCreateProject: () -> Void
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
                    isShowingProjects: true,
                    onShowProjects: showProjects,
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
                    onReturnToApp: mainWindowNavigation.dismissSettings
                )
            }
        } detail: {
            MainWindowPaneContent(isShowingSettings: isShowingSettings) {
                projectCatalog
            } settingsContent: {
                SettingsDetailView(
                    selection: mainWindowNavigation.settingsCategory,
                    captionViewModel: captionViewModel,
                    sidebarViewModel: sidebarViewModel,
                    appDatabase: appDatabase,
                    vaultManagementModel: vaultManagementModel
                )
            }
            .mainDetailPane()
        }
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
        } else {
            ProjectCatalogView(
                projects: sidebarViewModel.allProjectItems,
                pinnedProjectIDs: Set(mainWindowNavigation.pinnedProjectIDs(vaultId: sidebarViewModel.currentVault?.id)),
                canCreateMeeting: !captionViewModel.isRecordingStartPending && !captionViewModel.isFinalizingRecording,
                appearanceForProject: projectAppearance,
                onEditProject: onEditProject,
                onDeleteProject: onRequestProjectDeletion,
                onTogglePin: toggleProjectPin,
                onCreateMeeting: recordingCoordinator.createDraftMeeting,
                onCreateProject: onCreateProject
            )
        }
    }

    private func showProjects() {
        mainWindowNavigation.recordNavigation(to: .projects)
    }

    private func toggleProjectPin(_ project: ProjectOverviewItem) {
        mainWindowNavigation.toggleProjectPin(project.projectId, vaultId: sidebarViewModel.currentVault?.id)
    }

    private func projectAppearance(_ projectId: UUID) -> ProjectAppearance {
        mainWindowNavigation.projectAppearance(
            projectId: projectId,
            vaultId: sidebarViewModel.currentVault?.id
        )
    }
}
