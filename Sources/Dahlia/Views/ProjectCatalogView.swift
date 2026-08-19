import SwiftUI

struct ProjectCatalogView: View {
    enum SortField {
        case name
        case updated
    }

    let projects: [ProjectOverviewItem]
    let pinnedProjectIDs: Set<UUID>
    let canCreateMeeting: Bool
    let appearanceForProject: (UUID) -> ProjectAppearance
    let onEditProject: (ProjectOverviewItem) -> Void
    let onDeleteProject: (ProjectOverviewItem) -> Void
    let onTogglePin: (ProjectOverviewItem) -> Void
    let onCreateMeeting: (ProjectOverviewItem) -> Void
    let onCreateProject: () -> Void

    @State private var searchText = ""
    @State private var sortField = SortField.updated
    @State private var sortAscending = false

    var body: some View {
        let visibleProjects = Self.projects(
            projects,
            matching: searchText,
            sortedBy: sortField,
            ascending: sortAscending
        )

        VStack(alignment: .leading, spacing: 24) {
            Text(L10n.projects)
                .font(.title)
                .accessibilityAddTraits(.isHeader)

            TextField(L10n.searchProjects, text: $searchText)
                .textFieldStyle(.roundedBorder)

            if projects.isEmpty {
                ContentUnavailableView {
                    Label(L10n.noProjectsYet, systemImage: "folder.badge.plus")
                } description: {
                    Text(L10n.createFirstProjectDescription)
                } actions: {
                    Button(L10n.newProject, systemImage: "plus", action: onCreateProject)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visibleProjects.isEmpty {
                ContentUnavailableView {
                    Label(L10n.noProjectsMatchFilter, systemImage: "magnifyingglass")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    ProjectCatalogHeader(
                        sortField: sortField,
                        sortAscending: sortAscending,
                        onSort: updateSort
                    )
                    Divider()

                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(visibleProjects) { project in
                                ProjectCatalogRow(
                                    project: project,
                                    appearance: appearanceForProject(project.projectId),
                                    isPinned: pinnedProjectIDs.contains(project.projectId),
                                    canCreateMeeting: canCreateMeeting,
                                    onEdit: { onEditProject(project) },
                                    onDelete: { onDeleteProject(project) },
                                    onTogglePin: { onTogglePin(project) },
                                    onCreateMeeting: { onCreateMeeting(project) }
                                )
                                Divider()
                            }
                        }
                    }
                }
            }
        }
        .padding(.top, DahliaDesign.detailTopPadding)
        .padding(.horizontal, 48)
        .padding(.bottom, 24)
        .frame(maxWidth: DahliaDesign.mainContentMaxWidth, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    static func projects(
        _ projects: [ProjectOverviewItem],
        matching query: String,
        sortedBy sortField: SortField = .updated,
        ascending: Bool = false
    ) -> [ProjectOverviewItem] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return projects
            .filter { trimmedQuery.isEmpty || $0.projectName.localizedStandardContains(trimmedQuery) }
            .sorted {
                switch sortField {
                case .name:
                    let comparison = $0.projectName.localizedStandardCompare($1.projectName)
                    return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
                case .updated:
                    let firstDate = $0.latestMeetingDate ?? $0.createdAt
                    let secondDate = $1.latestMeetingDate ?? $1.createdAt
                    return firstDate == secondDate
                        ? $0.projectName.localizedStandardCompare($1.projectName) == .orderedAscending
                        : ascending ? firstDate < secondDate : firstDate > secondDate
                }
            }
    }

    private func updateSort(_ field: SortField) {
        if sortField == field {
            sortAscending.toggle()
        } else {
            sortField = field
            sortAscending = field == .name
        }
    }
}
