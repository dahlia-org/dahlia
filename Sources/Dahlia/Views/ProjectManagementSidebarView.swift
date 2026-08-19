import SwiftUI

struct ProjectManagementSidebarView: View {
    let projects: [ProjectOverviewItem]
    let hasVault: Bool
    let isLoaded: Bool
    let loadFailed: Bool
    @Binding var selectedProjectId: UUID?
    @Binding var expandedProjectIds: Set<UUID>
    let onRetry: () -> Void
    let onCreateProject: () -> Void
    let appearanceForProject: (UUID) -> ProjectAppearance

    private var projectNodes: [ProjectTreeNode] {
        ProjectTreeNode.buildNodes(from: projects)
    }

    var body: some View {
        List(selection: $selectedProjectId) {
            ProjectManagementSidebarContent(
                nodes: projectNodes,
                hasVault: hasVault,
                isLoaded: isLoaded,
                loadFailed: loadFailed,
                selectedProjectId: selectedProjectId,
                expandedProjectIds: $expandedProjectIds,
                onRetry: onRetry,
                onCreateProject: onCreateProject,
                appearanceForProject: appearanceForProject
            )
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }
}
