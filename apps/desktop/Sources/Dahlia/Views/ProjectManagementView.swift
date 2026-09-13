import SwiftUI

struct ProjectManagementView: View {
    @Binding var isSidebarVisible: Bool
    var sidebarViewModel: SidebarViewModel
    @ObservedObject var captionViewModel: CaptionViewModel
    var updateController: AppUpdateController
    let recordingCoordinator: RecordingCoordinator
    @Bindable var mainWindowNavigation: MainWindowNavigation
    let appDatabase: AppDatabaseManager?
    var workspaceManagementModel: WorkspaceManagementModel
    let onShowUpcomingSchedule: () -> Void
    let onShowChat: () -> Void
    let onShowUnprocessedRecordings: () -> Void
    let onCreateProject: () -> Void
    let onOpenProject: (UUID) -> Void
    let onOpenMeeting: (UUID) -> Void
    let onShowProjectCatalog: () -> Void
    let onEditProject: (ProjectOverviewItem) -> Void
    let onRequestProjectDeletion: (ProjectOverviewItem) -> Void
    let onOpenSidebarProject: (UUID, ProjectNavigationIntent) -> Void
    let onSelectWorkspace: (WorkspaceRecord) -> Void

    private var canEdit: Bool { sidebarViewModel.canEditCurrentWorkspace }

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
                    onCreateProject: onCreateProject,
                    onOpenProject: onOpenSidebarProject,
                    onSelectWorkspace: onSelectWorkspace
                )
            } settingsContent: {
                SettingsSidebarView(
                    selection: $mainWindowNavigation.settingsCategory,
                    workspaces: workspaceManagementModel.workspaces,
                    currentWorkspace: sidebarViewModel.currentWorkspace,
                    updateController: updateController,
                    onSelectWorkspace: onSelectWorkspace,
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
                    workspaceManagementModel: workspaceManagementModel,
                    onShowUnprocessedRecordings: openUnprocessedRecordingsFromSettings
                )
            }
            .mainDetailPane()
        }
        .onChange(of: sidebarViewModel.allProjectItems) {
            reconcileVisibleProject()
        }
    }

    private func openUnprocessedRecordingsFromSettings(workspaceID: UUID) {
        if sidebarViewModel.currentWorkspace?.id != workspaceID {
            guard let workspace = workspaceManagementModel.workspaces.first(where: { $0.id == workspaceID }) else { return }
            onSelectWorkspace(workspace)
            guard sidebarViewModel.currentWorkspace?.id == workspaceID else { return }
        }
        onShowUnprocessedRecordings()
        mainWindowNavigation.openUnprocessedRecordingsFromSettings()
    }

    @ViewBuilder
    private var projectCatalog: some View {
        if AppSettings.shared.currentWorkspace == nil {
            ContentUnavailableView {
                Label(L10n.noWorkspaceSelected, systemImage: "externaldrive")
            } description: {
                Text(L10n.projectManagementNoWorkspaceDescription)
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
                workspaceID: sidebarViewModel.currentWorkspace?.id,
                dbQueue: sidebarViewModel.dbQueue,
                workspaceChangeToken: sidebarViewModel.workspaceChangeToken,
                displayMode: mainWindowNavigation.projectDetailDisplayMode(workspaceId: sidebarViewModel.currentWorkspace?.id),
                onChangeDisplayMode: {
                    mainWindowNavigation.setProjectDetailDisplayMode($0, workspaceId: sidebarViewModel.currentWorkspace?.id)
                },
                onBack: onShowProjectCatalog,
                canEdit: canEdit,
                onEdit: { onEditProject(project) },
                onOpenMeeting: onOpenMeeting
            )
        } else {
            ProjectCatalogView(
                projects: sidebarViewModel.allProjectItems,
                pinnedProjectIDs: Set(mainWindowNavigation.pinnedProjectIDs(workspaceId: sidebarViewModel.currentWorkspace?.id)),
                canEdit: canEdit,
                canCreateMeeting: canEdit && !captionViewModel.isRecordingStartPending && !captionViewModel.isFinalizingRecording,
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
        mainWindowNavigation.toggleProjectPin(project.projectId, workspaceId: sidebarViewModel.currentWorkspace?.id)
    }

    private func projectAppearance(_ projectId: UUID) -> ProjectAppearance {
        mainWindowNavigation.projectAppearance(
            for: projectId,
            in: sidebarViewModel.projectItemsByID,
            workspaceId: sidebarViewModel.currentWorkspace?.id
        )
    }
}
