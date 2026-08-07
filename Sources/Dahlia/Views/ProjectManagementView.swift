import AppKit
import SwiftUI

struct ProjectManagementView: View {
    var sidebarViewModel: SidebarViewModel
    @ObservedObject var captionViewModel: CaptionViewModel
    let recordingCoordinator: RecordingCoordinator
    @Bindable var mainWindowNavigation: MainWindowNavigation
    let onShowUpcomingSchedule: () -> Void
    let onShowUnprocessedRecordings: () -> Void
    let showsCustomerIntelligence: Bool
    let onOpenCustomerIntelligence: () -> Void
    let onSelectVault: (VaultRecord) -> Void

    @State private var isShowingProjectCreation = false
    @State private var projectCreationParentId: UUID?
    @State private var newProjectName = ""
    @State private var newProjectType = ProjectType.undefined
    @State private var projectCreationErrorMessage = ""
    @State private var projectName = ""
    @State private var projectParentId: UUID?
    @State private var projectType = ProjectType.undefined
    @State private var projectPendingDeletion: ProjectOverviewItem?
    @State private var isShowingProjectOperationError = false
    @State private var projectOperationErrorMessage = ""
    @State private var projectDescription = ""
    @State private var descriptionStatusMessage: String?
    @State private var descriptionSaveFailed = false
    @State private var lastSavedProjectDescription = ""
    @State private var lastLoadedProjectRevision: Int?
    @State private var projectDescriptionExpectedRevision: Int?
    @State private var projectRevisionObservationTracker = ProjectRevisionObservationTracker()

    private let sidebarWidth: CGFloat = 300

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                MainSidebarNavigationView(
                    isShowingUpcomingSchedule: false,
                    onShowUpcomingSchedule: onShowUpcomingSchedule,
                    isShowingProjectManagement: true,
                    onShowProjectManagement: {},
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
                    searchText: $mainWindowNavigation.projectSearchText,
                    expandedProjectIds: $mainWindowNavigation.expandedProjectIds,
                    onRetry: sidebarViewModel.retryProjectCatalogLoading,
                    onCreateTopLevelProject: presentTopLevelProjectCreation,
                    onCreateSubproject: presentSubprojectCreation
                )

                if captionViewModel.isListening {
                    RecordingStatusBar(
                        viewModel: captionViewModel,
                        sidebarViewModel: sidebarViewModel,
                        recordingCoordinator: recordingCoordinator
                    )
                    .padding(8)
                } else if captionViewModel.canSwitchVault {
                    MainSidebarFooterView(
                        vaults: sidebarViewModel.allVaults,
                        currentVault: sidebarViewModel.currentVault,
                        onSelectVault: onSelectVault
                    )
                }
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: sidebarWidth, max: 420)
        } detail: {
            selectedProjectDetail
        }
        .onAppear {
            reconcileSelection(with: sidebarViewModel.allProjectItems)
            loadProjectDetails(for: mainWindowNavigation.selectedProjectId)
        }
        .onChange(of: sidebarViewModel.allProjectItems) { previousProjects, projects in
            reconcileSelection(with: projects)
            refreshSelectedProjectAfterExternalChange(from: previousProjects, to: projects)
        }
        .onChange(of: mainWindowNavigation.selectedProjectId) { oldProjectId, newProjectId in
            stageProjectDescriptionDraft(for: oldProjectId)
            loadProjectDetails(for: newProjectId)
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
        .sheet(isPresented: $isShowingProjectCreation) {
            ProjectCreationSheet(
                parentName: projectCreationParent?.projectName,
                projectName: $newProjectName,
                projectType: $newProjectType,
                errorMessage: projectCreationErrorMessage,
                onCancel: {
                    isShowingProjectCreation = false
                    projectCreationParentId = nil
                    projectCreationErrorMessage = ""
                },
                onCreate: createProject
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

    private var trimmedNewProjectName: String {
        newProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
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
                .navigationTitle(displayName(for: selectedProject.projectName))
        } else if sidebarViewModel.allProjectItems.isEmpty {
            ContentUnavailableView {
                Label(L10n.noProjectsYet, systemImage: "folder.badge.plus")
            } description: {
                Text(L10n.createFirstProjectDescription)
            } actions: {
                Button(L10n.newProject, systemImage: "plus", action: presentTopLevelProjectCreation)
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
                vaultName: vaultName
            )

            Form {
                projectNameSection(for: project)
                descriptionSection
                hierarchySection(for: project)
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

    private func hierarchySection(for project: ProjectOverviewItem) -> some View {
        Section {
            Picker(L10n.parentProject, selection: $projectParentId) {
                Text(L10n.vaultRoot).tag(UUID?.none)
                ForEach(projectReparentDestinations(for: project)) { candidate in
                    Text(candidate.projectName).tag(Optional(candidate.projectId))
                }
            }
            Button(L10n.moveProject, action: applyParentChange)
                .disabled(projectParentId == project.parentProjectId)

            if projectParentId == nil {
                Picker(L10n.projectType, selection: $projectType) {
                    ForEach(ProjectType.allCases, id: \.self) { type in
                        Text(L10n.projectTypeName(type)).tag(type)
                    }
                }
                Button(L10n.updateProjectType, action: applyTypeChange)
                    .disabled(
                        project.parentProjectId != nil
                            || projectType == projectedProjectType(for: project)
                    )
            } else {
                LabeledContent(L10n.projectType) {
                    VStack(alignment: .trailing) {
                        Text(L10n.projectTypeName(projectedProjectType(for: project)))
                        if let ownerName = projectedTypeOwnerProjectId(for: project).flatMap(projectName(id:)) {
                            Text(L10n.inheritedFromProject(ownerName))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

        } header: {
            Text(L10n.projectHierarchyAndType)
        } footer: {
            Text(L10n.projectHierarchyChangeHelp)
        }
    }

    private func projectNameSection(for project: ProjectOverviewItem) -> some View {
        Section {
            LabeledContent(L10n.projectName) {
                HStack {
                    TextField("", text: $projectName)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel(L10n.projectName)
                        .onSubmit(renameSelectedProject)

                    Button(L10n.renameProject, action: renameSelectedProject)
                        .disabled(!canRename(project))
                }
            }
        } footer: {
            Text(L10n.projectNameHelp)
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

    private func presentSubprojectCreation() {
        guard let selectedProject else { return }
        presentProjectCreation(parentProjectId: selectedProject.projectId)
    }

    private func presentTopLevelProjectCreation() {
        presentProjectCreation(parentProjectId: nil)
    }

    private func presentProjectCreation(parentProjectId: UUID?) {
        projectCreationParentId = parentProjectId
        newProjectName = ""
        newProjectType = .undefined
        projectCreationErrorMessage = ""
        isShowingProjectCreation = true
    }

    private func createProject() {
        let projectName = trimmedNewProjectName
        guard !projectName.isEmpty else { return }

        guard let project = sidebarViewModel.createProject(
            name: projectName,
            parentProjectId: projectCreationParentId,
            projectType: projectCreationParentId == nil ? newProjectType : nil
        ) else {
            projectCreationErrorMessage = sidebarViewModel.lastError ?? L10n.projectCreationFailedDescription
            return
        }

        mainWindowNavigation.projectSearchText = ""
        requestExpansion(toReveal: project.path)
        mainWindowNavigation.selectedProjectId = project.id
        isShowingProjectCreation = false
        projectCreationParentId = nil
        projectCreationErrorMessage = ""
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
        if projectRevisionObservationTracker.consume(
            projectId: selectedProjectId,
            revision: current.revision
        ) {
            requestExpansion(toReveal: current.projectName)
            return
        }

        projectRevisionObservationTracker.discard(projectId: selectedProjectId)
        let hadUnsavedFields = projectName != displayName(for: previous.projectName)
            || projectParentId != previous.parentProjectId
            || projectType != previous.effectiveProjectType
            || projectDescription != lastSavedProjectDescription
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
        projectName = project.map { displayName(for: $0.projectName) } ?? ""
        lastLoadedProjectRevision = project?.revision
        projectParentId = project?.parentProjectId
        projectType = project?.effectiveProjectType ?? .undefined
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

    private var projectCreationParent: ProjectOverviewItem? {
        guard let projectCreationParentId else { return nil }
        return sidebarViewModel.allProjectItems.first(where: { $0.projectId == projectCreationParentId })
    }

    private var descriptionStatusImage: String {
        if descriptionSaveFailed {
            "exclamationmark.triangle"
        } else {
            "checkmark.circle"
        }
    }

    private func canRename(_ project: ProjectOverviewItem) -> Bool {
        let trimmedName = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmedName.isEmpty
            && trimmedName != displayName(for: project.projectName)
    }

    private func renameSelectedProject() {
        guard let selectedProject else { return }
        let previousRevision = lastLoadedProjectRevision
        guard let renamed = sidebarViewModel.renameProject(
            id: selectedProject.projectId,
            newName: projectName,
            expectedRevision: lastLoadedProjectRevision
        ) else {
            showProjectOperationError()
            return
        }
        projectName = displayName(for: renamed.path)
        recordLocalProjectRevision(
            projectId: selectedProject.projectId,
            previousRevision: previousRevision,
            revision: renamed.revision
        )
        mainWindowNavigation.projectSearchText = ""
        requestExpansion(toReveal: renamed.path)
    }

    private func requestSelectedProjectDeletion() {
        guard let selectedProject else { return }
        projectPendingDeletion = selectedProject
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

    private func projectReparentDestinations(for project: ProjectOverviewItem) -> [ProjectOverviewItem] {
        ProjectDestinationOptions.reparentCandidates(
            for: project,
            projects: sidebarViewModel.allProjectItems
        )
    }

    private func projectedProjectType(for project: ProjectOverviewItem) -> ProjectType {
        guard let projectParentId else { return project.effectiveProjectType }
        return sidebarViewModel.allProjectItems
            .first(where: { $0.projectId == projectParentId })?
            .effectiveProjectType ?? .undefined
    }

    private func projectedTypeOwnerProjectId(for project: ProjectOverviewItem) -> UUID? {
        guard let projectParentId else { return project.projectId }
        return sidebarViewModel.allProjectItems
            .first(where: { $0.projectId == projectParentId })?
            .typeOwnerProjectId
    }

    private func applyParentChange() {
        guard let selectedProject else { return }
        let previousRevision = lastLoadedProjectRevision
        guard let moved = sidebarViewModel.reparentProject(
            id: selectedProject.projectId,
            parentProjectId: projectParentId,
            expectedRevision: lastLoadedProjectRevision
        ) else {
            showProjectOperationError()
            loadProjectDetails(for: selectedProject.projectId)
            return
        }
        recordLocalProjectRevision(
            projectId: selectedProject.projectId,
            previousRevision: previousRevision,
            revision: moved.revision
        )
        requestExpansion(toReveal: moved.path)
    }

    private func applyTypeChange() {
        guard let selectedProject else { return }
        let previousRevision = lastLoadedProjectRevision
        guard let updated = sidebarViewModel.updateRootProjectType(
            id: selectedProject.projectId,
            projectType: projectType,
            expectedRevision: lastLoadedProjectRevision
        ) else {
            showProjectOperationError()
            loadProjectDetails(for: mainWindowNavigation.selectedProjectId)
            return
        }
        recordLocalProjectRevision(
            projectId: selectedProject.projectId,
            previousRevision: previousRevision,
            revision: updated.revision
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
        projectRevisionObservationTracker.record(projectId: projectId, revision: revision)
    }

    private func projectName(id: UUID) -> String? {
        sidebarViewModel.allProjectItems.first(where: { $0.projectId == id })?.projectName
    }

    private func requestExpansion(toReveal projectName: String) {
        let ancestorIds = sidebarViewModel.allProjectItems.compactMap { project -> UUID? in
            projectName.hasPrefix(project.projectName + "/") ? project.projectId : nil
        }
        mainWindowNavigation.expandedProjectIds.formUnion(ancestorIds)
    }

    private func displayName(for projectName: String) -> String {
        projectName.split(separator: "/").last.map(String.init) ?? projectName
    }

    private func showProjectOperationError() {
        projectOperationErrorMessage = sidebarViewModel.lastError ?? L10n.projectOperationFailedDescription
        isShowingProjectOperationError = true
    }
}
