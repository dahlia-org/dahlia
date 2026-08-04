import SwiftUI

struct MainNavigationSidebar: View {
    @Binding var selection: MainNavigationRoute
    let projects: [FlatProjectRow]
    let showsOrganizations: Bool
    let openProjectManager: () -> Void
    let openOrganizationWindow: () -> Void

    var body: some View {
        List(selection: $selection) {
            Section {
                Label(L10n.calendarScheduleTitle, systemImage: "calendar")
                    .tag(MainNavigationRoute.schedule)
                Label(L10n.meetings, systemImage: "waveform")
                    .tag(MainNavigationRoute.meetings)
            }

            Section(L10n.projects) {
                ForEach(projects) { project in
                    Label(project.displayName, systemImage: "folder")
                        .padding(.leading, CGFloat(project.depth) * 12)
                        .tag(MainNavigationRoute.project(project.id))
                        .help(project.name)
                }

                Button(L10n.manageProjects, systemImage: "slider.horizontal.3", action: openProjectManager)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }

            if showsOrganizations {
                Section {
                    Label(L10n.organizations, systemImage: "building.2")
                        .tag(MainNavigationRoute.organizations)
                        .contextMenu {
                            Button(L10n.openOrganizationWorkspace, systemImage: "macwindow", action: openOrganizationWindow)
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle(L10n.dahlia)
    }
}
