import SwiftUI

/// The Projects section's detail pane: the project catalog, or one project's detail.
struct ProjectManagementView: View {
    var sidebarViewModel: SidebarViewModel
    @ObservedObject var captionViewModel: CaptionViewModel
    let recordingCoordinator: RecordingCoordinator
    var mainWindowNavigation: MainWindowNavigation
    let onCreateProject: () -> Void
    let onOpenProject: (UUID) -> Void
    let onOpenMeeting: (UUID) -> Void
    let onShowProjectCatalog: () -> Void
    let onEditProject: (ProjectOverviewItem) -> Void
    let onRequestProjectDeletion: (ProjectOverviewItem) -> Void

    private var canEdit: Bool { sidebarViewModel.canEditCurrentWorkspace }

    var body: some View {
        projectCatalog
            .onChange(of: sidebarViewModel.allProjectItems) {
                reconcileVisibleProject()
            }
    }

    @ViewBuilder
    private var projectCatalog: some View {
        if AppSettings.shared.currentWorkspace == nil {
            ContentUnavailableView {
                Label(L10n.noWorkspaceSelected, systemImage: ProjectIcon.workspace.systemImageName)
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
