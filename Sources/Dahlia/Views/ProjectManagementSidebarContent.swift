import SwiftUI

struct ProjectManagementSidebarContent: View {
    let projects: [ProjectOverviewItem]
    let filteredNodes: [ProjectTreeNode]
    let hasVault: Bool
    let isLoaded: Bool
    let loadFailed: Bool
    let selectedProjectId: UUID?
    let expandsAllDescendants: Bool
    @Binding var expandedProjectIds: Set<UUID>
    let onRetry: () -> Void
    let onCreateTopLevelProject: () -> Void
    let onClearSearch: () -> Void

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
        } else if filteredNodes.isEmpty {
            emptyState
        } else {
            ForEach(filteredNodes) { node in
                ProjectManagementTreeRow(
                    node: node,
                    selectedProjectId: selectedProjectId,
                    expandedProjectIds: $expandedProjectIds,
                    expandsAllDescendants: expandsAllDescendants
                )
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(emptyStateTitle, systemImage: emptyStateSystemImage)
        } description: {
            Text(emptyStateDescription)
        } actions: {
            if projects.isEmpty {
                Button(L10n.newProject, systemImage: "plus", action: onCreateTopLevelProject)
            } else {
                Button(L10n.clearSearch, action: onClearSearch)
            }
        }
        .listRowSeparator(.hidden)
    }

    private var emptyStateTitle: String {
        projects.isEmpty ? L10n.noProjectsYet : L10n.noResultsFound
    }

    private var emptyStateDescription: String {
        projects.isEmpty ? L10n.createFirstProjectDescription : L10n.noProjectsMatchFilter
    }

    private var emptyStateSystemImage: String {
        projects.isEmpty ? "folder.badge.plus" : "magnifyingglass"
    }
}
