import AppKit
import SwiftUI

struct ProjectManagementView: View {
    var sidebarViewModel: SidebarViewModel

    @ObservedObject private var driveStore = GoogleDriveStore.shared
    @State private var selectedProjectId: UUID?
    @State private var projectSearchText = ""
    @State private var pickingProjectId: UUID?
    @State private var contextText = ""
    @State private var contextFileURL: URL?
    @State private var contextStatusMessage: String?
    @State private var contextStatusSystemImage = "checkmark.circle"
    @State private var contextStatusTint = Color.secondary
    @State private var lastSavedContextText = ""
    @State private var isLoadingContext = false
    @State private var contextSaveTask: Task<Void, Never>?

    private let sidebarWidth: CGFloat = 300
    private let folderProjectService = FolderProjectService()

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
            loadContextForSelectedProject()
        }
        .onChange(of: sidebarViewModel.allProjectItems) { _, projects in
            reconcileSelection(with: projects)
        }
        .onChange(of: selectedProjectId) { _, _ in
            loadContextForSelectedProject()
        }
        .onChange(of: contextText) { _, _ in
            scheduleContextSave()
        }
        .onDisappear {
            contextSaveTask?.cancel()
            persistContextIfNeeded()
        }
        .task {
            await driveStore.restoreSessionIfNeeded()
        }
        .sheet(item: pickingProjectBinding) { project in
            GoogleDriveFolderPickerView { folder in
                sidebarViewModel.updateProjectGoogleDriveFolder(id: project.projectId, folderId: folder.id)
                pickingProjectId = nil
            }
        }
    }

    private var filteredProjects: [ProjectOverviewItem] {
        let query = projectSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sidebarViewModel.allProjectItems }
        return sidebarViewModel.allProjectItems.filter { project in
            project.projectName.localizedCaseInsensitiveContains(query)
        }
    }

    private var selectedProject: ProjectOverviewItem? {
        guard let selectedProjectId else { return nil }
        return sidebarViewModel.allProjectItems.first(where: { $0.projectId == selectedProjectId })
    }

    private var projectSidebar: some View {
        List(selection: $selectedProjectId) {
            if filteredProjects.isEmpty {
                ContentUnavailableView {
                    Label(
                        sidebarViewModel.allProjectItems.isEmpty ? L10n.noProjectsYet : L10n.noResultsFound,
                        systemImage: "folder"
                    )
                }
                .listRowSeparator(.hidden)
            } else {
                ForEach(filteredProjects) { project in
                    ProjectManagementRow(project: project)
                        .tag(project.projectId)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle(L10n.projects)
        .searchable(text: $projectSearchText, prompt: L10n.searchProjects)
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
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    projectHeader(selectedProject)
                    contextSection(for: selectedProject)
                    destinationSection(for: selectedProject)
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 28)
                .frame(maxWidth: 780, alignment: .leading)
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .navigationTitle(selectedProject.projectName)
        } else {
            ContentUnavailableView {
                Label(L10n.projects, systemImage: "folder")
            } description: {
                Text(L10n.selectProjectToManageDescription)
            }
        }
    }

    private func projectHeader(_ project: ProjectOverviewItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(project.projectName)
                .font(.largeTitle.weight(.semibold))
                .lineLimit(2)

            HStack(spacing: 10) {
                Label(L10n.meetingCount(project.meetingCount), systemImage: "text.bubble")
                    .foregroundStyle(.secondary)

                if project.missingOnDisk {
                    Label(L10n.missingOnDisk, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
            .font(.callout)
        }
    }

    private func destinationSection(for project: ProjectOverviewItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: L10n.summaryDestinations, description: L10n.summaryDestinationsDescription)

            VStack(spacing: 0) {
                projectFolderRow(for: project)
                Divider()
                googleDriveRow(for: project)
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 1)
            }
        }
    }

    private func contextSection(for project: ProjectOverviewItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: L10n.projectContext, description: L10n.projectContextDescription)

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Label(L10n.contextFile, systemImage: "doc.text")
                        .font(.headline)

                    Spacer(minLength: 0)

                    if let contextStatusMessage {
                        Label(contextStatusMessage, systemImage: contextStatusSystemImage)
                            .font(.callout)
                            .foregroundStyle(contextStatusTint)
                    }

                    Button {
                        ensureContextFile(for: project)
                    } label: {
                        Label(L10n.createContextFile, systemImage: "doc.badge.plus")
                    }
                    .disabled(projectFolderURL(for: project) == nil)

                    Button {
                        openContextFile()
                    } label: {
                        Label(L10n.openContextFile, systemImage: "square.and.arrow.up")
                    }
                    .disabled(contextFileURL == nil)
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 12)

                Divider()

                TextEditor(text: $contextText)
                    .font(.body.monospaced())
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 260)
                    .padding(12)
                    .background(Color(nsColor: .textBackgroundColor))
                    .disabled(contextFileURL == nil)
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 1)
            }
        }
    }

    private func sectionHeader(title: String, description: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title3.weight(.semibold))

            Text(description)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func projectFolderRow(for project: ProjectOverviewItem) -> some View {
        SettingsControlRow(
            title: L10n.localSummaryFolder,
            description: projectFolderPath(for: project) ?? L10n.noVaultSelected
        ) {
            Button {
                openProjectFolder(for: project)
            } label: {
                Label(L10n.openInFinder, systemImage: "folder")
            }
            .disabled(projectFolderURL(for: project) == nil)
        }
    }

    private func googleDriveRow(for project: ProjectOverviewItem) -> some View {
        SettingsControlRow(
            title: L10n.googleDrive,
            description: googleDriveDescription(for: project)
        ) {
            HStack(spacing: 8) {
                if let folderURL = googleDriveFolderURL(for: project) {
                    Button {
                        NSWorkspace.shared.open(folderURL)
                    } label: {
                        Label(L10n.openInBrowser, systemImage: "safari")
                    }
                    .labelStyle(.iconOnly)
                    .help(L10n.openInBrowser)
                }

                Button(project.googleDriveFolderId?.isEmpty == false ? L10n.changeFolder : L10n.chooseFolder) {
                    pickingProjectId = project.projectId
                }
                .disabled(!driveStore.isAuthorized)

                if project.googleDriveFolderId?.isEmpty == false {
                    Button(L10n.clear) {
                        sidebarViewModel.updateProjectGoogleDriveFolder(id: project.projectId, folderId: nil)
                    }
                }
            }
        }
    }

    private func googleDriveDescription(for project: ProjectOverviewItem) -> String {
        if !driveStore.isConfigured {
            return L10n.googleAccountClientIDMissingMessage
        }
        if !driveStore.isAuthorized {
            return L10n.googleDriveConnectDescription
        }
        if project.googleDriveFolderId?.isEmpty == false {
            return L10n.googleDriveFolderConfigured
        }
        return L10n.googleDriveNoFolderSelected
    }

    private var pickingProjectBinding: Binding<ProjectOverviewItem?> {
        Binding(
            get: {
                guard let pickingProjectId else { return nil }
                return sidebarViewModel.allProjectItems.first(where: { $0.projectId == pickingProjectId })
            },
            set: { project in
                pickingProjectId = project?.projectId
            }
        )
    }

    private func selectInitialProjectIfNeeded() {
        guard selectedProjectId == nil else { return }
        selectedProjectId = sidebarViewModel.allProjectItems.first?.projectId
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

    private func googleDriveFolderURL(for project: ProjectOverviewItem) -> URL? {
        guard let folderId = project.googleDriveFolderId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !folderId.isEmpty else { return nil }
        return URL(string: "https://drive.google.com/drive/folders/\(folderId)")
    }

    private func loadContextForSelectedProject() {
        contextSaveTask?.cancel()
        guard let selectedProject else {
            contextText = ""
            lastSavedContextText = ""
            contextFileURL = nil
            contextStatusMessage = nil
            return
        }
        loadContext(for: selectedProject)
    }

    private func loadContext(for project: ProjectOverviewItem) {
        guard let projectURL = projectFolderURL(for: project) else {
            contextText = ""
            lastSavedContextText = ""
            contextFileURL = nil
            contextStatusMessage = nil
            return
        }

        isLoadingContext = true
        defer { isLoadingContext = false }

        do {
            try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
            guard let url = folderProjectService.ensureContextFileExists(at: projectURL) else {
                contextText = ""
                lastSavedContextText = ""
                contextFileURL = nil
                contextStatusMessage = L10n.contextUnavailable
                contextStatusSystemImage = "exclamationmark.triangle"
                contextStatusTint = .orange
                return
            }
            contextFileURL = url
            contextText = try folderProjectService.readContext(at: projectURL)
            lastSavedContextText = contextText
            contextStatusMessage = nil
        } catch {
            contextText = ""
            lastSavedContextText = ""
            contextFileURL = nil
            contextStatusMessage = L10n.contextLoadFailed(error.localizedDescription)
            contextStatusSystemImage = "exclamationmark.triangle"
            contextStatusTint = .orange
        }
    }

    private func ensureContextFile(for project: ProjectOverviewItem) {
        loadContext(for: project)
    }

    private func openContextFile() {
        guard let contextFileURL else { return }
        NSWorkspace.shared.open(contextFileURL)
    }

    private func scheduleContextSave() {
        guard !isLoadingContext,
              contextFileURL != nil,
              contextText != lastSavedContextText else { return }
        contextSaveTask?.cancel()
        contextSaveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            persistContextIfNeeded()
        }
    }

    private func persistContextIfNeeded() {
        guard !isLoadingContext,
              let selectedProject,
              let projectURL = projectFolderURL(for: selectedProject),
              contextFileURL != nil,
              contextText != lastSavedContextText else { return }

        do {
            contextFileURL = try folderProjectService.writeContext(contextText, at: projectURL)
            lastSavedContextText = contextText
            contextStatusMessage = L10n.contextSaved
            contextStatusSystemImage = "checkmark.circle"
            contextStatusTint = .secondary
        } catch {
            contextStatusMessage = L10n.contextSaveFailed(error.localizedDescription)
            contextStatusSystemImage = "exclamationmark.triangle"
            contextStatusTint = .orange
        }
    }
}

private struct ProjectManagementRow: View {
    let project: ProjectOverviewItem

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(project.projectName)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(L10n.meetingCount(project.meetingCount))

                    if project.missingOnDisk {
                        Text(L10n.missingOnDisk)
                    }
                }
                .font(.caption)
                .foregroundStyle(project.missingOnDisk ? .orange : .secondary)
                .lineLimit(1)
            }
        } icon: {
            Image(systemName: project.missingOnDisk ? "folder.badge.questionmark" : "folder")
                .foregroundStyle(project.missingOnDisk ? .orange : .secondary)
        }
    }
}
