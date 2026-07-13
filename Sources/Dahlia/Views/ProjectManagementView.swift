import AppKit
import SwiftUI

struct ProjectManagementView: View {
    var sidebarViewModel: SidebarViewModel

    @State private var selectedProjectId: UUID?
    @State private var projectSearchText = ""
    @State private var isShowingProjectCreation = false
    @State private var projectCreationParentId: UUID?
    @State private var newProjectName = ""
    @State private var isShowingProjectCreationError = false
    @State private var projectCreationErrorMessage = ""
    @State private var projectName = ""
    @State private var projectPendingDeletion: ProjectOverviewItem?
    @State private var requestedExpandedProjectIds: Set<UUID> = []
    @State private var isShowingProjectOperationError = false
    @State private var projectOperationErrorMessage = ""
    @State private var projectDescription = ""
    @State private var descriptionStatusMessage: String?
    @State private var descriptionSaveFailed = false
    @State private var lastSavedProjectDescription = ""
    @State private var descriptionSaveTask: Task<Void, Never>?

    private let sidebarWidth: CGFloat = 300

    var body: some View {
        NavigationSplitView {
            projectSidebar
                .navigationSplitViewColumnWidth(min: 260, ideal: sidebarWidth, max: 360)
        } detail: {
            selectedProjectDetail
        }
        .frame(minWidth: 900, minHeight: 580)
        .onAppear {
            selectInitialProjectIfNeeded()
            loadProjectDetails(for: selectedProjectId)
        }
        .onChange(of: sidebarViewModel.allProjectItems) { _, projects in
            reconcileSelection(with: projects)
        }
        .onChange(of: selectedProjectId) { oldProjectId, newProjectId in
            descriptionSaveTask?.cancel()
            persistProjectDescriptionIfNeeded(for: oldProjectId)
            loadProjectDetails(for: newProjectId)
        }
        .onChange(of: projectDescription) { _, _ in
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
                    deleteProject(project, meetingDisposition: disposition)
                }
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

    private var projectSidebar: some View {
        List(selection: $selectedProjectId) {
            if filteredProjectNodes.isEmpty {
                ContentUnavailableView {
                    Label(
                        sidebarViewModel.allProjectItems.isEmpty ? L10n.noProjectsYet : L10n.noResultsFound,
                        systemImage: "folder"
                    )
                }
                .listRowSeparator(.hidden)
            } else {
                ForEach(filteredProjectNodes) { node in
                    ProjectManagementTreeRow(
                        node: node,
                        selectedProjectId: selectedProjectId,
                        requestedExpandedProjectIds: requestedExpandedProjectIds
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
        .alert(L10n.newProject, isPresented: $isShowingProjectCreation) {
            TextField(L10n.projectName, text: $newProjectName)
            Button(L10n.cancel, role: .cancel) {
                projectCreationParentId = nil
            }
            Button(L10n.create, action: createProject)
                .disabled(trimmedNewProjectName.isEmpty)
        } message: {
            if let parent = projectCreationParent {
                Text(L10n.projectCreationLocation(parent.projectName))
            } else {
                Text(L10n.projectCreationAtVaultTop)
            }
        }
        .alert(L10n.projectCreationFailed, isPresented: $isShowingProjectCreationError) {} message: {
            Text(projectCreationErrorMessage)
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
        } else if let selectedProject {
            projectDetailForm(for: selectedProject)
                .navigationTitle(selectedProject.projectName)
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
        Form {
            Section {
                Label(L10n.meetingCount(project.meetingCount), systemImage: "text.bubble")
                    .foregroundStyle(.secondary)

                if project.missingOnDisk {
                    Label(L10n.missingOnDisk, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }

            projectNameSection(for: project)
            descriptionSection
            destinationSection(for: project)
            projectDeletionSection
        }
        .formStyle(.grouped)
    }

    private func projectNameSection(for project: ProjectOverviewItem) -> some View {
        Section {
            LabeledContent(L10n.projectName) {
                HStack {
                    TextField(L10n.projectName, text: $projectName)
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

    private func presentProjectCreation(parentProjectId: UUID?) {
        projectCreationParentId = parentProjectId
        newProjectName = ""
        isShowingProjectCreation = true
    }

    private func createProject() {
        let projectName = trimmedNewProjectName
        guard !projectName.isEmpty else { return }
        defer { projectCreationParentId = nil }

        guard let project = sidebarViewModel.createProject(
            leafName: projectName,
            parentProjectId: projectCreationParentId
        ) else {
            projectCreationErrorMessage = sidebarViewModel.lastError ?? L10n.projectCreationFailedDescription
            isShowingProjectCreationError = true
            return
        }

        projectSearchText = ""
        requestExpansion(toReveal: project.name)
        selectedProjectId = project.id
    }

    private func reconcileSelection(with projects: [ProjectOverviewItem]) {
        if let selectedProjectId, projects.contains(where: { $0.projectId == selectedProjectId }) {
            return
        }
        selectedProjectId = projects.first?.projectId
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
        let description = projectId.flatMap(sidebarViewModel.projectDescription(id:)) ?? ""
        projectDescription = description
        lastSavedProjectDescription = description
        descriptionStatusMessage = nil
        projectName = projectId
            .flatMap { id in sidebarViewModel.allProjectItems.first(where: { $0.projectId == id }) }
            .map { leafName(for: $0.projectName) }
            ?? ""
    }

    private func scheduleProjectDescriptionSave() {
        guard let selectedProjectId,
              projectDescription != lastSavedProjectDescription else { return }
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

    private func persistProjectDescriptionIfNeeded(for projectId: UUID?) {
        guard let projectId,
              projectDescription != lastSavedProjectDescription else { return }

        if sidebarViewModel.updateProjectDescription(id: projectId, description: projectDescription) {
            lastSavedProjectDescription = projectDescription
            descriptionStatusMessage = L10n.saved
            descriptionSaveFailed = false
        } else {
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
    ) -> Bool {
        descriptionSaveTask?.cancel()
        guard sidebarViewModel.deleteProjectHierarchy(
            id: project.projectId,
            meetingDisposition: meetingDisposition
        ) else {
            showProjectOperationError()
            return false
        }
        if selectedProjectId == project.projectId
            || projectHierarchy(for: project).contains(where: { $0.projectId == selectedProjectId }) {
            selectedProjectId = nil
        }
        return true
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
        projectOperationErrorMessage = sidebarViewModel.lastError ?? L10n.projectCreationFailedDescription
        isShowingProjectOperationError = true
    }
}
