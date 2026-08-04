import SwiftUI

struct MainNavigationSidebar: View {
    private static let disclosureControlSize: CGFloat = 28

    @Binding var selection: MainNavigationRoute
    let projects: [FlatProjectRow]
    let showsOrganizations: Bool
    let openProjectManager: () -> Void
    let openOrganizationWindow: () -> Void
    @State private var collapsedProjectIDs: Set<UUID> = []

    var body: some View {
        List(selection: $selection) {
            Section {
                Label(L10n.calendarScheduleTitle, systemImage: "calendar")
                    .tag(MainNavigationRoute.schedule)
                Label(L10n.meetings, systemImage: "waveform")
                    .tag(MainNavigationRoute.meetings)

                if showsOrganizations {
                    Label(L10n.organizations, systemImage: "building.2")
                        .tag(MainNavigationRoute.organizations)
                        .contextMenu {
                            Button(L10n.openOrganizationWorkspace, systemImage: "macwindow", action: openOrganizationWindow)
                        }
                }

                Button(L10n.manageProjects, systemImage: "slider.horizontal.3", action: openProjectManager)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }

            Section(L10n.projects) {
                ForEach(visibleProjects) { project in
                    projectRow(project)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle(L10n.dahlia)
        .onChange(of: projects.map(\.id)) { _, projectIDs in
            collapsedProjectIDs.formIntersection(projectIDs)
        }
    }

    private var visibleProjects: [FlatProjectRow] {
        FlatProjectRow.visibleRows(
            in: projects,
            collapsedProjectIDs: collapsedProjectIDs
        )
    }

    private func projectRow(_ project: FlatProjectRow) -> some View {
        let isCollapsed = collapsedProjectIDs.contains(project.id)

        return HStack(spacing: 6) {
            if project.hasChildren {
                Button {
                    toggleExpansion(of: project)
                } label: {
                    Label(
                        isCollapsed ? L10n.expand : L10n.collapse,
                        systemImage: isCollapsed ? "chevron.right" : "chevron.down"
                    )
                    .labelStyle(.iconOnly)
                    .frame(
                        width: Self.disclosureControlSize,
                        height: Self.disclosureControlSize
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help(isCollapsed ? L10n.expand : L10n.collapse)
            } else {
                Color.clear
                    .frame(
                        width: Self.disclosureControlSize,
                        height: Self.disclosureControlSize
                    )
            }

            Label(project.displayName, systemImage: "folder")
        }
        .padding(.leading, CGFloat(project.depth) * 12)
        .tag(MainNavigationRoute.project(project.id))
        .help(project.name)
    }

    private func toggleExpansion(of project: FlatProjectRow) {
        if collapsedProjectIDs.remove(project.id) == nil {
            collapsedProjectIDs.insert(project.id)
            if case let .project(selectedProjectID) = selection,
               projects.first(where: { $0.id == selectedProjectID })?.isDescendant(of: project) == true {
                selection = .project(project.id)
            }
        }
    }
}
