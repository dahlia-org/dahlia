import AppKit
import SwiftUI

struct ProjectManagementView: View {
    var sidebarViewModel: SidebarViewModel

    @State private var selectedProjectId: UUID?
    @State private var projectSearchText = ""
    @State private var isShowingProjectCreation = false
    @State private var projectCreationParentId: UUID?
    @State private var newProjectName = ""
    @State private var newProjectType = ProjectType.undefined
    @State private var projectCreationErrorMessage = ""
    @State private var projectName = ""
    @State private var projectParentId: UUID?
    @State private var projectType = ProjectType.undefined
    @State private var projectPendingDeletion: ProjectOverviewItem?
    @State private var requestedExpandedProjectIds: Set<UUID> = []
    @State private var isShowingProjectOperationError = false
    @State private var projectOperationErrorMessage = ""
    @State private var projectDescription = ""
    @State private var descriptionStatusMessage: String?
    @State private var descriptionSaveFailed = false
    @State private var lastSavedProjectDescription = ""
    @State private var lastLoadedProjectRevision: Int?
    @State private var descriptionSaveTask: Task<Void, Never>?
    @State private var isRevertingSelectionAfterSaveFailure = false
    @State private var projectDescriptionChangeTracker = ProjectDescriptionChangeTracker()

    private let sidebarWidth: CGFloat = 300

    var body: some View {
        NavigationSplitView {
            projectSidebar
                .navigationSplitViewColumnWidth(min: 260, ideal: sidebarWidth, max: 360)
        } detail: {
            selectedProjectDetail
        }
        .frame(minWidth: 800, minHeight: 520)
        .onAppear {
            selectInitialProjectIfNeeded()
            loadProjectDetails(for: selectedProjectId)
        }
        .onChange(of: sidebarViewModel.allProjectItems) { previousProjects, projects in
            reconcileSelection(with: projects)
            refreshSelectedProjectAfterExternalChange(from: previousProjects, to: projects)
        }
        .onChange(of: selectedProjectId) { oldProjectId, newProjectId in
            if isRevertingSelectionAfterSaveFailure {
                isRevertingSelectionAfterSaveFailure = false
                return
            }
            descriptionSaveTask?.cancel()
            if !persistProjectDescriptionIfNeeded(for: oldProjectId) {
                isRevertingSelectionAfterSaveFailure = true
                selectedProjectId = oldProjectId
                return
            }
            loadProjectDetails(for: newProjectId)
        }
        .onChange(of: projectDescription) { _, newDescription in
            guard projectDescriptionChangeTracker.shouldSaveChange(to: newDescription) else { return }
            scheduleProjectDescriptionSave()
        }
        .onDisappear {
            descriptionSaveTask?.cancel()
            persistProjectDescriptionIfNeeded(for: selectedProjectId)
        }
        .sheet(item: $projectPendingDeletion) { project in
            let hierarchy = projectHierarchy(for: project)
            ProjectDeletionDialog(
                project: project,
                projectCount: hierarchy.count,
                meetingCount: hierarchy.reduce(0) { $0 + $1.meetingCount },
                moveDestinations: projectMoveDestinations(excluding: project),
                onConfirm: { disposition in
                    await deleteProject(project, meetingDisposition: disposition)
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

    private var projectNodes: [ProjectTreeNode] {
        ProjectTreeNode.buildNodes(from: sidebarViewModel.allProjectItems)
    }

    private var filteredProjectNodes: [ProjectTreeNode] {
        let query = projectSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return projectNodes }
        return projectNodes.compactMap { $0.filtered(matching: query) }
    }

    private var selectedProject: ProjectOverviewItem? {
        guard let selectedProjectId else { return nil }
        return sidebarViewModel.allProjectItems.first(where: { $0.projectId == selectedProjectId })
    }

    private var trimmedNewProjectName: String {
        newProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSearchingProjects: Bool {
        !projectSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var emptyProjectStateTitle: String {
        if sidebarViewModel.allProjectItems.isEmpty {
            L10n.noProjectsYet
        } else {
            L10n.noResultsFound
        }
    }

    private var emptyProjectStateDescription: String {
        if sidebarViewModel.allProjectItems.isEmpty {
            L10n.createFirstProjectDescription
        } else {
            L10n.noProjectsMatchFilter
        }
    }

    private var emptyProjectStateSystemImage: String {
        if sidebarViewModel.allProjectItems.isEmpty {
            "folder.badge.plus"
        } else {
            "magnifyingglass"
        }
    }

    private var projectSidebar: some View {
        let filteredNodes = filteredProjectNodes

        return List(selection: $selectedProjectId) {
            if AppSettings.shared.currentVault == nil {
                ContentUnavailableView {
                    Label(L10n.noVaultSelected, systemImage: "externaldrive")
                } description: {
                    Text(L10n.projectManagementNoVaultDescription)
                }
                .listRowSeparator(.hidden)
            } else if !sidebarViewModel.isProjectCatalogLoaded {
                ProgressView(L10n.loadingProjects)
                    .frame(maxWidth: .infinity)
                    .listRowSeparator(.hidden)
            } else if sidebarViewModel.projectCatalogLoadFailed {
                ContentUnavailableView {
                    Label(L10n.projectCatalogLoadFailed, systemImage: "exclamationmark.triangle")
                } description: {
                    Text(L10n.projectCatalogLoadFailedDescription)
                } actions: {
                    Button(L10n.retry, action: sidebarViewModel.retryProjectCatalogLoading)
                }
                .listRowSeparator(.hidden)
            } else if filteredNodes.isEmpty {
                ContentUnavailableView {
                    Label(emptyProjectStateTitle, systemImage: emptyProjectStateSystemImage)
                } description: {
                    Text(emptyProjectStateDescription)
                } actions: {
                    if sidebarViewModel.allProjectItems.isEmpty {
                        Button(L10n.newProject, systemImage: "plus", action: presentTopLevelProjectCreation)
                    } else {
                        Button(L10n.clearSearch, action: clearProjectSearch)
                    }
                }
                .listRowSeparator(.hidden)
            } else {
                ForEach(filteredNodes) { node in
                    ProjectManagementTreeRow(
                        node: node,
                        selectedProjectId: selectedProjectId,
                        expandedProjectIds: $requestedExpandedProjectIds,
                        expandsAllDescendants: isSearchingProjects
                    )
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle(L10n.projects)
        .searchable(text: $projectSearchText, prompt: L10n.searchProjects)
        .toolbar {
            ToolbarItem {
                if let selectedProject {
                    Menu(L10n.newProject, systemImage: "plus") {
                        Button(
                            L10n.newSubproject,
                            systemImage: "folder.badge.plus",
                            action: presentSubprojectCreation
                        )
                        .disabled(selectedProject.missingOnDisk)

                        Button(
                            L10n.newTopLevelProject,
                            systemImage: "externaldrive.badge.plus",
                            action: presentTopLevelProjectCreation
                        )
                    }
                    .disabled(AppSettings.shared.currentVault == nil)
                    .help(L10n.newProject)
                } else {
                    Button(L10n.newProject, systemImage: "plus", action: presentTopLevelProjectCreation)
                        .disabled(AppSettings.shared.currentVault == nil)
                        .help(L10n.newProject)
                }
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
                .navigationTitle(leafName(for: selectedProject.projectName))
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

        return Form {
            ProjectContextSectionView(
                vaultName: AppSettings.shared.currentVault?.name ?? L10n.vault,
                project: project,
                parentName: project.parentProjectId.flatMap(projectName(id:)),
                includedSubprojectCount: max(hierarchy.count - 1, 0),
                hierarchyMeetingCount: hierarchy.reduce(0) { $0 + $1.meetingCount }
            )

            projectNameSection(for: project)
            hierarchySection(for: project)
            descriptionSection
            destinationSection(for: project)
            projectDeletionSection
        }
        .formStyle(.grouped)
    }

    private func hierarchySection(for project: ProjectOverviewItem) -> some View {
        Section {
            Picker(L10n.parentProject, selection: $projectParentId) {
                Text(L10n.vaultRoot).tag(UUID?.none)
                ForEach(projectMoveDestinations(excluding: project)) { candidate in
                    Text(candidate.projectName).tag(Optional(candidate.projectId))
                }
            }
            Button(L10n.moveProject, action: applyParentChange)
                .disabled(project.missingOnDisk || projectParentId == project.parentProjectId)

            if projectParentId == nil {
                Picker(L10n.projectType, selection: $projectType) {
                    ForEach(ProjectType.allCases, id: \.self) { type in
                        Text(L10n.projectTypeName(type)).tag(type)
                    }
                }
                Button(L10n.updateProjectType, action: applyTypeChange)
                    .disabled(
                        project.missingOnDisk
                            || project.parentProjectId != nil
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

            if let descriptionStatusMessage {
                HStack {
                    SettingsStatusMessage(
                        text: descriptionStatusMessage,
                        systemImage: descriptionStatusImage,
                        tint: descriptionSaveFailed ? .orange : .secondary
                    )

                    if descriptionSaveFailed {
                        Button(L10n.retry) {
                            persistProjectDescriptionIfNeeded(for: selectedProjectId)
                        }
                    }
                }
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
            .disabled(projectFolderURL(for: project) == nil)
        } label: {
            Text(L10n.localSummaryFolder)
            Text(projectFolderPath(for: project) ?? L10n.noVaultSelected)
        }
    }

    private func selectInitialProjectIfNeeded() {
        guard selectedProjectId == nil else { return }
        selectedProjectId = sidebarViewModel.allProjectItems.first?.projectId
    }

    private func presentSubprojectCreation() {
        guard let selectedProject else { return }
        presentProjectCreation(parentProjectId: selectedProject.projectId)
    }

    private func presentTopLevelProjectCreation() {
        presentProjectCreation(parentProjectId: nil)
    }

    private func clearProjectSearch() {
        projectSearchText = ""
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
            leafName: projectName,
            parentProjectId: projectCreationParentId,
            projectType: projectCreationParentId == nil ? newProjectType : nil
        ) else {
            projectCreationErrorMessage = sidebarViewModel.lastError ?? L10n.projectCreationFailedDescription
            return
        }

        projectSearchText = ""
        requestExpansion(toReveal: project.name)
        selectedProjectId = project.id
        isShowingProjectCreation = false
        projectCreationParentId = nil
        projectCreationErrorMessage = ""
    }

    private func reconcileSelection(with projects: [ProjectOverviewItem]) {
        if let selectedProjectId, projects.contains(where: { $0.projectId == selectedProjectId }) {
            return
        }
        selectedProjectId = projects.first?.projectId
    }

    private func refreshSelectedProjectAfterExternalChange(
        from previousProjects: [ProjectOverviewItem],
        to projects: [ProjectOverviewItem]
    ) {
        guard let selectedProjectId,
              let previous = previousProjects.first(where: { $0.projectId == selectedProjectId }),
              let current = projects.first(where: { $0.projectId == selectedProjectId }),
              previous.revision != current.revision else {
            return
        }

        let hadUnsavedFields = projectName != leafName(for: previous.projectName)
            || projectParentId != previous.parentProjectId
            || projectType != previous.effectiveProjectType
            || projectDescription != lastSavedProjectDescription
        descriptionSaveTask?.cancel()
        descriptionSaveTask = nil
        loadProjectDetails(for: selectedProjectId)
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
        guard let url = projectFolderURL(for: project) else { return }
        NSWorkspace.shared.open(url)
    }

    private func loadProjectDetails(for projectId: UUID?) {
        let editingState = ProjectDescriptionEditingState(
            persistedText: projectId.flatMap { sidebarViewModel.projectDescription(id: $0) },
            draftText: projectId.flatMap { sidebarViewModel.projectDescriptionDraft(id: $0) }
        )
        projectDescriptionChangeTracker.prepareForProgrammaticChange(
            from: projectDescription,
            to: editingState.text
        )
        projectDescription = editingState.text
        lastSavedProjectDescription = editingState.persistedText
        descriptionStatusMessage = editingState.hasUnsavedChanges ? L10n.projectDescriptionSaveFailed : nil
        descriptionSaveFailed = editingState.hasUnsavedChanges
        projectName = projectId
            .flatMap { id in sidebarViewModel.allProjectItems.first(where: { $0.projectId == id }) }
            .map { leafName(for: $0.projectName) }
            ?? ""
        let project = projectId.flatMap { id in
            sidebarViewModel.allProjectItems.first(where: { $0.projectId == id })
        }
        lastLoadedProjectRevision = project?.revision
        projectParentId = project?.parentProjectId
        projectType = project?.effectiveProjectType ?? .undefined
    }

    private func scheduleProjectDescriptionSave() {
        guard let selectedProjectId,
              projectDescription != lastSavedProjectDescription else { return }
        sidebarViewModel.stageProjectDescriptionDraft(id: selectedProjectId, description: projectDescription)
        descriptionStatusMessage = L10n.saving
        descriptionSaveFailed = false
        descriptionSaveTask?.cancel()
        descriptionSaveTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(450))
            } catch {
                return
            }
            persistProjectDescriptionIfNeeded(for: selectedProjectId)
        }
    }

    @discardableResult
    private func persistProjectDescriptionIfNeeded(for projectId: UUID?) -> Bool {
        guard let projectId,
              projectDescription != lastSavedProjectDescription else { return true }

        switch sidebarViewModel.updateProjectDescription(
            id: projectId,
            description: projectDescription,
            expectedRevision: lastLoadedProjectRevision
        ) {
        case .saved:
            lastSavedProjectDescription = projectDescription
            lastLoadedProjectRevision = sidebarViewModel.allProjectItems
                .first(where: { $0.projectId == projectId })?
                .revision
            descriptionStatusMessage = L10n.saved
            descriptionSaveFailed = false
        case .projectNotFound:
            descriptionStatusMessage = nil
            descriptionSaveFailed = false
        case let .staleRevision(current):
            lastLoadedProjectRevision = current
            descriptionStatusMessage = L10n.staleProjectRevision(current)
            descriptionSaveFailed = true
            return false
        case .failed:
            descriptionStatusMessage = L10n.projectDescriptionSaveFailed
            descriptionSaveFailed = true
            return false
        }
        return true
    }

    private var projectCreationParent: ProjectOverviewItem? {
        guard let projectCreationParentId else { return nil }
        return sidebarViewModel.allProjectItems.first(where: { $0.projectId == projectCreationParentId })
    }

    private var descriptionStatusImage: String {
        if descriptionSaveFailed {
            "exclamationmark.triangle"
        } else if descriptionStatusMessage == L10n.saving {
            "arrow.triangle.2.circlepath"
        } else {
            "checkmark.circle"
        }
    }

    private func canRename(_ project: ProjectOverviewItem) -> Bool {
        let trimmedName = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !project.missingOnDisk
            && !trimmedName.isEmpty
            && trimmedName != leafName(for: project.projectName)
    }

    private func renameSelectedProject() {
        guard let selectedProject else { return }
        persistProjectDescriptionIfNeeded(for: selectedProject.projectId)
        guard let renamed = sidebarViewModel.renameProject(
            id: selectedProject.projectId,
            newLeafName: projectName
        ) else {
            showProjectOperationError()
            return
        }
        projectName = leafName(for: renamed.name)
        projectSearchText = ""
        requestExpansion(toReveal: renamed.name)
    }

    private func requestSelectedProjectDeletion() {
        guard let selectedProject else { return }
        projectPendingDeletion = selectedProject
    }

    private func deleteProject(
        _ project: ProjectOverviewItem,
        meetingDisposition: ProjectMeetingDisposition
    ) async -> String? {
        descriptionSaveTask?.cancel()
        guard await sidebarViewModel.deleteProjectHierarchy(
            id: project.projectId,
            meetingDisposition: meetingDisposition
        ) else {
            return sidebarViewModel.lastError ?? L10n.projectOperationFailedDescription
        }
        if selectedProjectId == project.projectId
            || projectHierarchy(for: project).contains(where: { $0.projectId == selectedProjectId }) {
            selectedProjectId = nil
        }
        return nil
    }

    private func projectHierarchy(for project: ProjectOverviewItem) -> [ProjectOverviewItem] {
        sidebarViewModel.allProjectItems.filter {
            ProjectRecord.belongsToHierarchy($0.projectName, prefix: project.projectName)
        }
    }

    private func projectMoveDestinations(excluding project: ProjectOverviewItem) -> [ProjectOverviewItem] {
        sidebarViewModel.allProjectItems.filter {
            !$0.missingOnDisk
                && !ProjectRecord.belongsToHierarchy($0.projectName, prefix: project.projectName)
        }
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
        guard let moved = sidebarViewModel.reparentProject(
            id: selectedProject.projectId,
            parentProjectId: projectParentId
        ) else {
            showProjectOperationError()
            loadProjectDetails(for: selectedProject.projectId)
            return
        }
        requestExpansion(toReveal: moved.name)
        loadProjectDetails(for: selectedProject.projectId)
    }

    private func applyTypeChange() {
        guard let selectedProject,
              sidebarViewModel.updateRootProjectType(
                  id: selectedProject.projectId,
                  projectType: projectType
              ) != nil else {
            showProjectOperationError()
            loadProjectDetails(for: selectedProjectId)
            return
        }
        loadProjectDetails(for: selectedProject.projectId)
    }

    private func projectName(id: UUID) -> String? {
        sidebarViewModel.allProjectItems.first(where: { $0.projectId == id })?.projectName
    }

    private func requestExpansion(toReveal projectName: String) {
        let ancestorIds = sidebarViewModel.allProjectItems.compactMap { project -> UUID? in
            projectName.hasPrefix(project.projectName + "/") ? project.projectId : nil
        }
        requestedExpandedProjectIds.formUnion(ancestorIds)
    }

    private func leafName(for projectName: String) -> String {
        projectName.split(separator: "/").last.map(String.init) ?? projectName
    }

    private func showProjectOperationError() {
        projectOperationErrorMessage = sidebarViewModel.lastError ?? L10n.projectOperationFailedDescription
        isShowingProjectOperationError = true
    }
}

private struct ProjectCreationSheet: View {
    let parentName: String?
    @Binding var projectName: String
    @Binding var projectType: ProjectType
    let errorMessage: String
    let onCancel: () -> Void
    let onCreate: () -> Void

    var body: some View {
        Form {
            Section {
                LabeledContent(L10n.parentProject, value: parentName ?? L10n.vaultRoot)
                TextField(L10n.projectName, text: $projectName)
                if parentName == nil {
                    Picker(L10n.projectType, selection: $projectType) {
                        ForEach(ProjectType.allCases, id: \.self) { type in
                            Text(L10n.projectTypeName(type)).tag(type)
                        }
                    }
                } else {
                    Text(L10n.subprojectTypeInheritanceHelp)
                        .foregroundStyle(.secondary)
                }
                if !errorMessage.isEmpty {
                    SettingsStatusMessage(
                        text: errorMessage,
                        systemImage: "exclamationmark.triangle",
                        tint: .orange
                    )
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 420, minHeight: 220)
        .navigationTitle(L10n.newProject)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button(L10n.cancel, role: .cancel, action: onCancel)
                Button(L10n.create, action: onCreate)
                    .keyboardShortcut(.defaultAction)
                    .disabled(projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
            .background(.bar)
        }
    }
}
