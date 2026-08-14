import SwiftUI

struct ProjectManagementSidebarContent: View {
    let nodes: [ProjectTreeNode]
    let hasVault: Bool
    let isLoaded: Bool
    let loadFailed: Bool
    let selectedProjectId: UUID?
    @Binding var expandedProjectIds: Set<UUID>
    let onRetry: () -> Void
    let onCreateTopLevelProject: () -> Void

    var body: some View {
        if !hasVault {
            ContentUnavailableView {
                Label(L10n.noVaultSelected, systemImage: "externaldrive")
            } description: {
                Text(L10n.projectManagementNoVaultDescription)
            }
            .listRowSeparator(.hidden)
        } else if !isLoaded {
            ProgressView(L10n.loadingProjects)
                .frame(maxWidth: .infinity)
                .listRowSeparator(.hidden)
        } else if loadFailed {
            ContentUnavailableView {
                Label(L10n.projectCatalogLoadFailed, systemImage: "exclamationmark.triangle")
            } description: {
                Text(L10n.projectCatalogLoadFailedDescription)
            } actions: {
                Button(L10n.retry, action: onRetry)
            }
            .listRowSeparator(.hidden)
        } else if nodes.isEmpty {
            emptyState
        } else {
            ForEach(nodes) { node in
                ProjectManagementTreeRow(
                    node: node,
                    selectedProjectId: selectedProjectId,
                    expandedProjectIds: $expandedProjectIds,
                    expandsAllDescendants: false
                )
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(L10n.noProjectsYet, systemImage: "folder.badge.plus")
        } description: {
            Text(L10n.createFirstProjectDescription)
        } actions: {
            Button(L10n.newProject, systemImage: "plus", action: onCreateTopLevelProject)
        }
        .listRowSeparator(.hidden)
    }
}
