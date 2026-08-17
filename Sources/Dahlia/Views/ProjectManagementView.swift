import AppKit
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
    let onEditProject: (ProjectOverviewItem, String?, Int?) -> Void
    let usesMeetingSidebar: Bool
    let onOpenSidebarProject: (UUID, ProjectNavigationIntent) -> Void
    let onSelectVault: (VaultRecord) -> Void

    @State private var projectPendingDeletion: ProjectOverviewItem?
    @State private var isShowingProjectOperationError = false
    @State private var projectOperationErrorMessage = ""
    @State private var projectDescription = ""
    @State private var descriptionStatusMessage: String?
    @State private var descriptionSaveFailed = false
    @State private var lastSavedProjectDescription = ""
    @State private var lastLoadedProjectRevision: Int?
    @State private var projectDescriptionExpectedRevision: Int?
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
                sidebarContent
            } settingsContent: {
                SettingsSidebarView(
                    selection: $mainWindowNavigation.settingsCategory,
                    onReturnToApp: mainWindowNavigation.dismissSettings
                )
            }
        } detail: {
            MainWindowPaneContent(isShowingSettings: isShowingSettings) {
                selectedProjectDetail
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
        .onAppear {
            reconcileSelection(with: sidebarViewModel.allProjectItems)
            loadProjectDetails(for: mainWindowNavigation.selectedProjectId)
            handlePendingProjectNavigationIntent()
        }
        .onChange(of: sidebarViewModel.allProjectItems) { previousProjects, projects in
            reconcileSelection(with: projects)
            refreshSelectedProjectAfterExternalChange(from: previousProjects, to: projects)
            handlePendingProjectNavigationIntent()
        }
        .onChange(of: mainWindowNavigation.selectedProjectId) { oldProjectId, newProjectId in
            stageProjectDescriptionDraft(for: oldProjectId)
            loadProjectDetails(for: newProjectId)
        }
        .onChange(of: mainWindowNavigation.pendingProjectNavigationIntent) {
            handlePendingProjectNavigationIntent()
        }
        .onChange(of: projectDescription) {
            stageProjectDescriptionDraft(for: mainWindowNavigation.selectedProjectId)
        }
        .onDisappear {
            stageProjectDescriptionDraft(for: mainWindowNavigation.selectedProjectId)
        }
        .onChange(of: sidebarViewModel.currentVault?.id) { _, vaultId in
            mainWindowNavigation.reconcileProjectCatalog(
                vaultId: vaultId,
                projects: sidebarViewModel.allProjectItems
            )
        }
        .sheet(item: $projectPendingDeletion) { project in
            let hierarchy = projectHierarchy(for: project)
            ProjectDeletionDialog(
                project: project,
                projectCount: hierarchy.count,
                meetingCount: hierarchy.reduce(0) { $0 + $1.meetingCount },
                moveDestinations: ProjectDestinationOptions.meetingMoveCandidates(
                    whenDeleting: project,
                    projects: sidebarViewModel.allProjectItems
                ),
                onConfirm: { disposition, deletesSummaryFiles in
                    await deleteProject(
                        project,
                        meetingDisposition: disposition,
                        deletesSummaryFiles: deletesSummaryFiles
                    )
                }
            )
        }
        .alert(L10n.projectOperationFailed, isPresented: $isShowingProjectOperationError) {} message: {
            Text(projectOperationErrorMessage)
        }
    }

    private var selectedProject: ProjectOverviewItem? {
        guard let selectedProjectId = mainWindowNavigation.selectedProjectId else { return nil }
        return sidebarViewModel.allProjectItems.first(where: { $0.projectId == selectedProjectId })
    }

    @ViewBuilder
    private var sidebarContent: some View {
        if usesMeetingSidebar {
            MeetingListSidebarView(
                viewModel: captionViewModel,
                updateController: updateController,
                sidebarViewModel: sidebarViewModel,
                mainWindowNavigation: mainWindowNavigation,
                recordingCoordinator: recordingCoordinator,
                isShowingUpcomingSchedule: false,
                onShowUpcomingSchedule: onShowUpcomingSchedule,
                isShowingUnprocessedRecordings: false,
                onShowUnprocessedRecordings: onShowUnprocessedRecordings,
                showsCustomerIntelligence: showsCustomerIntelligence,
                onOpenCustomerIntelligence: onOpenCustomerIntelligence,
                onCreateProject: onCreateProject,
                onOpenProject: onOpenSidebarProject,
                onSelectVault: onSelectVault
            )
        } else {
            VStack(spacing: 0) {
                MainSidebarNavigationView(
                    onCreateMeeting: recordingCoordinator.createDraftMeeting,
                    canCreateMeeting: !captionViewModel.isRecordingStartPending && !captionViewModel.isFinalizingRecording,
                    canStartQuickRecording: recordingCoordinator.canStartNewMeeting,
                    onStartQuickRecording: recordingCoordinator.startQuickRecording,
                    isShowingUpcomingSchedule: false,
                    onShowUpcomingSchedule: onShowUpcomingSchedule,
                    isShowingUnprocessedRecordings: false,
                    unprocessedRecordingCount: sidebarViewModel.unprocessedRecordingItems.count,
                    onShowUnprocessedRecordings: onShowUnprocessedRecordings,
                    showsCustomerIntelligence: showsCustomerIntelligence,
                    onOpenCustomerIntelligence: onOpenCustomerIntelligence
                )
                SidebarSectionHeader(title: L10n.projects)
                ProjectManagementSidebarView(
                    projects: sidebarViewModel.allProjectItems,
                    hasVault: AppSettings.shared.currentVault != nil,
                    isLoaded: sidebarViewModel.isProjectCatalogLoaded,
                    loadFailed: sidebarViewModel.projectCatalogLoadFailed,
                    selectedProjectId: $mainWindowNavigation.selectedProjectId,
                    expandedProjectIds: $mainWindowNavigation.expandedProjectIds,
                    onRetry: sidebarViewModel.retryProjectCatalogLoading,
                    onCreateProject: onCreateProject,
                    appearanceForProject: projectAppearance
                )

                MainSidebarBottomArea(
                    viewModel: captionViewModel,
                    sidebarViewModel: sidebarViewModel,
                    recordingCoordinator: recordingCoordinator,
                    updateController: updateController,
                    onSelectVault: onSelectVault
                )
            }
        }
    }

    @ViewBuilder
    private var selectedProjectDetail: some View {
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
        } else if let selectedProject {
            projectDetailForm(for: selectedProject)
        } else if sidebarViewModel.allProjectItems.isEmpty {
            ContentUnavailableView {
                Label(L10n.noProjectsYet, systemImage: "folder.badge.plus")
            } description: {
                Text(L10n.createFirstProjectDescription)
            } actions: {
                Button(L10n.newProject, systemImage: "plus", action: onCreateProject)
            }
        } else {
            ContentUnavailableView {
                Label(L10n.projects, systemImage: "folder")
            } description: {
                Text(L10n.selectProjectToManageDescription)
            }
        }
    }

}

private extension ProjectManagementView {

    private func projectDetailForm(for project: ProjectOverviewItem) -> some View {
        let hierarchy = projectHierarchy(for: project)
        let vaultName = AppSettings.shared.currentVault?.name ?? L10n.vault

        return VStack(spacing: 0) {
            ProjectDetailHeaderView(
                projectName: displayName(for: project.projectName),
                projectPath: project.projectName,
                vaultName: vaultName,
                appearance: projectAppearance(project.projectId),
                onEdit: {
                    onEditProject(project, projectDescription, projectDescriptionExpectedRevision)
                }
            )

            Form {
                descriptionSection
                ProjectContextSectionView(
                    project: project,
                    includedSubprojectCount: max(hierarchy.count - 1, 0),
                    hierarchyMeetingCount: hierarchy.reduce(0) { $0 + $1.meetingCount }
                )
                destinationSection(for: project)
                projectDeletionSection
            }
            .formStyle(.grouped)
        }
    }

    private var descriptionSection: some View {
        Section {
            TextField(
                L10n.projectDescription,
                text: $projectDescription,
                prompt: Text(L10n.projectDescriptionPlaceholder),
                axis: .vertical
            )
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .lineLimit(6 ... 12)
            .accessibilityLabel(L10n.projectDescription)

            HStack {
                if let descriptionStatusMessage {
                    SettingsStatusMessage(
                        text: descriptionStatusMessage,
                        systemImage: descriptionStatusImage,
                        tint: descriptionSaveFailed ? .orange : .secondary
                    )
                }

                Spacer()

                Button(L10n.save, action: saveProjectDescription)
                    .disabled(projectDescription == lastSavedProjectDescription)
            }
        } header: {
            Text(L10n.projectDescription)
        } footer: {
            Text(L10n.projectDescriptionHelp)
        }
    }

    private var projectDeletionSection: some View {
        Section {
            Button(L10n.deleteProject, systemImage: "trash", role: .destructive, action: requestSelectedProjectDeletion)
        } header: {
            Text(L10n.dangerZone)
        } footer: {
            Text(L10n.deleteProjectHelp)
        }
    }

    private func destinationSection(for project: ProjectOverviewItem) -> some View {
        Section {
            projectFolderRow(for: project)
        } header: {
            Text(L10n.summaryDestinations)
        } footer: {
            Text(L10n.summaryDestinationsDescription)
        }
    }

    private func projectFolderRow(for project: ProjectOverviewItem) -> some View {
        LabeledContent {
            Button {
                openProjectFolder(for: project)
            } label: {
                Label(L10n.openInFinder, systemImage: "folder")
            }
        } label: {
            Text(L10n.localSummaryFolder)
            Text(projectFolderPath(for: project) ?? L10n.noVaultSelected)
        }
    }

    private func reconcileSelection(with projects: [ProjectOverviewItem]) {
        mainWindowNavigation.reconcileProjectCatalog(
            vaultId: sidebarViewModel.currentVault?.id,
            projects: projects
        )
    }

    private func refreshSelectedProjectAfterExternalChange(
        from previousProjects: [ProjectOverviewItem],
        to projects: [ProjectOverviewItem]
    ) {
        guard let selectedProjectId = mainWindowNavigation.selectedProjectId,
              let previous = previousProjects.first(where: { $0.projectId == selectedProjectId }),
              let current = projects.first(where: { $0.projectId == selectedProjectId }),
              previous.revision != current.revision else {
            return
        }
        if mainWindowNavigation.consumeLocalProjectRevision(
            projectId: selectedProjectId,
            revision: current.revision
        ) {
            projectDescription = current.projectDescription
            lastSavedProjectDescription = current.projectDescription
            lastLoadedProjectRevision = current.revision
            projectDescriptionExpectedRevision = current.revision
            sidebarViewModel.clearProjectDescriptionDraft(id: selectedProjectId)
            descriptionStatusMessage = nil
            descriptionSaveFailed = false
            requestExpansion(toReveal: current.projectName)
            return
        }

        mainWindowNavigation.discardLocalProjectRevisions(projectId: selectedProjectId)
        let hadUnsavedFields = projectDescription != lastSavedProjectDescription
        loadProjectDetails(for: selectedProjectId)
        requestExpansion(toReveal: current.projectName)
        if hadUnsavedFields {
            projectOperationErrorMessage = L10n.staleProjectRevision(current.revision)
            isShowingProjectOperationError = true
        }
    }

    private func projectFolderURL(for project: ProjectOverviewItem) -> URL? {
        guard AppSettings.shared.currentVault != nil else { return nil }
        return sidebarViewModel.projectURL(for: project.projectName)
    }

    private func projectFolderPath(for project: ProjectOverviewItem) -> String? {
        projectFolderURL(for: project)?.path
    }

    private func openProjectFolder(for project: ProjectOverviewItem) {
        guard let url = projectFolderURL(for: project),
              let vaultURL = AppSettings.shared.currentVault?.url else { return }
        Task {
            let status = await Task.detached {
                ProjectFolderSafety.status(of: url, inside: vaultURL)
            }.value
            switch status {
            case .available:
                NSWorkspace.shared.open(url)
            case .missing:
                projectOperationErrorMessage = L10n.summaryOutputFolderNotCreated
                isShowingProjectOperationError = true
            case .unsafe:
                projectOperationErrorMessage = L10n.invalidSummaryOutputDestination
                isShowingProjectOperationError = true
            }
        }
    }

    private func loadProjectDetails(for projectId: UUID?) {
        let project = projectId.flatMap { id in
            sidebarViewModel.allProjectItems.first(where: { $0.projectId == id })
        }
        let editingState = ProjectDescriptionEditingState(
            persistedText: projectId.flatMap { sidebarViewModel.projectDescription(id: $0) },
            draftText: projectId.flatMap { sidebarViewModel.projectDescriptionDraft(id: $0) },
            persistedRevision: project?.revision,
            draftRevision: projectId.flatMap { sidebarViewModel.projectDescriptionDraftBaseRevision(id: $0) }
        )
        projectDescription = editingState.text
        lastSavedProjectDescription = editingState.persistedText
        projectDescriptionExpectedRevision = editingState.expectedRevision
        descriptionStatusMessage = nil
        descriptionSaveFailed = false
        lastLoadedProjectRevision = project?.revision
    }

    private func stageProjectDescriptionDraft(for projectId: UUID?) {
        guard let projectId else { return }
        if projectDescription == lastSavedProjectDescription {
            sidebarViewModel.clearProjectDescriptionDraft(id: projectId)
        } else {
            sidebarViewModel.stageProjectDescriptionDraft(
                id: projectId,
                description: projectDescription,
                baseRevision: projectDescriptionExpectedRevision
            )
        }
        descriptionStatusMessage = nil
        descriptionSaveFailed = false
    }

    private func saveProjectDescription() {
        guard let selectedProjectId = mainWindowNavigation.selectedProjectId,
              projectDescription != lastSavedProjectDescription else { return }

        switch sidebarViewModel.updateProjectDescription(
            id: selectedProjectId,
            description: projectDescription,
            expectedRevision: projectDescriptionExpectedRevision
        ) {
        case .saved:
            let previousRevision = lastLoadedProjectRevision
            lastSavedProjectDescription = projectDescription
            if let committedRevision = lastLoadedProjectRevision.map({ $0 + 1 }) {
                recordLocalProjectRevision(
                    projectId: selectedProjectId,
                    previousRevision: previousRevision,
                    revision: committedRevision
                )
            }
            descriptionStatusMessage = L10n.saved
            descriptionSaveFailed = false
        case .projectNotFound:
            descriptionStatusMessage = nil
            descriptionSaveFailed = false
        case let .staleRevision(current):
            lastLoadedProjectRevision = current
            projectDescriptionExpectedRevision = current
            sidebarViewModel.stageProjectDescriptionDraft(
                id: selectedProjectId,
                description: projectDescription,
                baseRevision: current
            )
            descriptionStatusMessage = L10n.staleProjectRevision(current)
            descriptionSaveFailed = true
        case .failed:
            descriptionStatusMessage = L10n.projectDescriptionSaveFailed
            descriptionSaveFailed = true
        }
    }

    private var descriptionStatusImage: String {
        if descriptionSaveFailed {
            "exclamationmark.triangle"
        } else {
            "checkmark.circle"
        }
    }

    private func requestSelectedProjectDeletion() {
        guard let selectedProject else { return }
        projectPendingDeletion = selectedProject
    }

    private func handlePendingProjectNavigationIntent() {
        guard let projectId = mainWindowNavigation.selectedProjectId,
              let project = selectedProject,
              let intent = mainWindowNavigation.consumeProjectNavigationIntent(for: projectId) else { return }
        switch intent {
        case .open:
            break
        case .edit:
            onEditProject(project, projectDescription, projectDescriptionExpectedRevision)
        case .delete:
            requestSelectedProjectDeletion()
        }
    }

    private func deleteProject(
        _ project: ProjectOverviewItem,
        meetingDisposition: ProjectMeetingDisposition,
        deletesSummaryFiles: Bool
    ) async -> String? {
        guard await sidebarViewModel.deleteProjectHierarchy(
            id: project.projectId,
            meetingDisposition: meetingDisposition,
            deletesSummaryFiles: deletesSummaryFiles
        ) else {
            return sidebarViewModel.lastError ?? L10n.projectOperationFailedDescription
        }
        if mainWindowNavigation.selectedProjectId == project.projectId
            || projectHierarchy(for: project).contains(where: {
                $0.projectId == mainWindowNavigation.selectedProjectId
            }) {
            mainWindowNavigation.selectedProjectId = nil
        }
        return nil
    }

    private func projectHierarchy(for project: ProjectOverviewItem) -> [ProjectOverviewItem] {
        ProjectDestinationOptions.hierarchy(
            for: project,
            projects: sidebarViewModel.allProjectItems
        )
    }

    private func recordLocalProjectRevision(
        projectId: UUID,
        previousRevision: Int?,
        revision: Int
    ) {
        lastLoadedProjectRevision = revision
        if projectDescriptionExpectedRevision == previousRevision {
            projectDescriptionExpectedRevision = revision
            if projectDescription != lastSavedProjectDescription {
                sidebarViewModel.stageProjectDescriptionDraft(
                    id: projectId,
                    description: projectDescription,
                    baseRevision: revision
                )
            }
        }
        mainWindowNavigation.recordLocalProjectRevision(projectId: projectId, revision: revision)
    }

    private func requestExpansion(toReveal projectName: String) {
        let ancestorIds = ProjectManagementSelection.ancestorIDs(
            toReveal: projectName,
            projects: sidebarViewModel.allProjectItems
        )
        mainWindowNavigation.expandedProjectIds.formUnion(ancestorIds)
    }

    private func displayName(for projectName: String) -> String {
        projectName.split(separator: "/").last.map(String.init) ?? projectName
    }

    private func projectAppearance(_ projectId: UUID) -> ProjectAppearance {
        mainWindowNavigation.projectAppearance(
            projectId: projectId,
            vaultId: sidebarViewModel.currentVault?.id
        )
    }
}
