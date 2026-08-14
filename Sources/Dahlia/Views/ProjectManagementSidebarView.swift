import SwiftUI

struct ProjectManagementSidebarView: View {
    let projects: [ProjectOverviewItem]
    let hasVault: Bool
    let isLoaded: Bool
    let loadFailed: Bool
    @Binding var selectedProjectId: UUID?
    @Binding var expandedProjectIds: Set<UUID>
    let onRetry: () -> Void
    let onCreateTopLevelProject: () -> Void
    let onCreateSubproject: () -> Void

    @Environment(MainWindowNavigation.self) private var mainWindowNavigation

    private var projectNodes: [ProjectTreeNode] {
        ProjectTreeNode.buildNodes(from: projects)
    }

    private var selectedProject: ProjectOverviewItem? {
        guard let selectedProjectId else { return nil }
        return projects.first(where: { $0.projectId == selectedProjectId })
    }

    var body: some View {
        projectList
            .toolbar {
                if !mainWindowNavigation.isShowingSettings {
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
    }

    private var projectList: some View {
        List(selection: $selectedProjectId) {
            ProjectManagementSidebarContent(
                nodes: projectNodes,
                hasVault: hasVault,
                isLoaded: isLoaded,
                loadFailed: loadFailed,
                selectedProjectId: selectedProjectId,
                expandedProjectIds: $expandedProjectIds,
                onRetry: onRetry,
                onCreateTopLevelProject: onCreateTopLevelProject
            )
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }
}
