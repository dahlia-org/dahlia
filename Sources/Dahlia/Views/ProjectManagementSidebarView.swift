import SwiftUI

struct ProjectManagementSidebarView: View {
    let projects: [ProjectOverviewItem]
    let hasVault: Bool
    let isLoaded: Bool
    let loadFailed: Bool
    @Binding var selectedProjectId: UUID?
    @Binding var searchText: String
    @Binding var expandedProjectIds: Set<UUID>
    let onRetry: () -> Void
    let onCreateTopLevelProject: () -> Void
    let onCreateSubproject: () -> Void

    private var projectNodes: [ProjectTreeNode] {
        ProjectTreeNode.buildNodes(from: projects)
    }

    private var filteredProjectNodes: [ProjectTreeNode] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return projectNodes }
        return projectNodes.compactMap { $0.filtered(matching: query) }
    }

    private var selectedProject: ProjectOverviewItem? {
        guard let selectedProjectId else { return nil }
        return projects.first(where: { $0.projectId == selectedProjectId })
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        List(selection: $selectedProjectId) {
            ProjectManagementSidebarContent(
                projects: projects,
                filteredNodes: filteredProjectNodes,
                hasVault: hasVault,
                isLoaded: isLoaded,
                loadFailed: loadFailed,
                selectedProjectId: selectedProjectId,
                expandsAllDescendants: isSearching,
                expandedProjectIds: $expandedProjectIds,
                onRetry: onRetry,
                onCreateTopLevelProject: onCreateTopLevelProject,
                onClearSearch: clearSearch
            )
        }
        .listStyle(.sidebar)
        .searchable(text: $searchText, prompt: L10n.searchProjects)
        .toolbar {
            ToolbarItem {
                ProjectCreationMenu(
                    selectedProject: selectedProject,
                    hasVault: hasVault,
                    onCreateTopLevelProject: onCreateTopLevelProject,
                    onCreateSubproject: onCreateSubproject
                )
            }
        }
    }

    private func clearSearch() {
        searchText = ""
    }
}
