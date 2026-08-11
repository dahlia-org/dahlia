import SwiftUI

struct ProjectCreationMenu: View {
    let selectedProject: ProjectOverviewItem?
    let hasVault: Bool
    let onCreateTopLevelProject: () -> Void
    let onCreateSubproject: () -> Void

    var body: some View {
        if let selectedProject {
            Menu(L10n.newProject, systemImage: "plus") {
                Button(
                    L10n.newSubproject,
                    systemImage: "folder.badge.plus",
                    action: onCreateSubproject
                )
                .disabled(selectedProject.parentProjectId != nil)

                Button(
                    L10n.newTopLevelProject,
                    systemImage: "externaldrive.badge.plus",
                    action: onCreateTopLevelProject
                )
            }
            .disabled(!hasVault)
            .help(L10n.newProject)
        } else {
            Button(L10n.newProject, systemImage: "plus", action: onCreateTopLevelProject)
                .disabled(!hasVault)
                .help(L10n.newProject)
        }
    }
}
