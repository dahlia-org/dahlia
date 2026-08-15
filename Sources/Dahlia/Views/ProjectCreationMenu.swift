import SwiftUI

struct ProjectCreationMenu: View {
    let selectedProject: ProjectOverviewItem?
    let hasVault: Bool
    let onCreateTopLevelProject: () -> Void
    let onCreateSubproject: () -> Void

    var body: some View {
        Group {
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
            } else {
                Button(L10n.newProject, systemImage: "plus", action: onCreateTopLevelProject)
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .controlSize(.small)
        .disabled(!hasVault)
        .help(L10n.newProject)
    }
}
