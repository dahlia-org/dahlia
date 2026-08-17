import SwiftUI

struct ProjectEditorHierarchyFields: View {
    let parentProjects: [ProjectOverviewItem]
    @Binding var parentProjectId: UUID?
    @Binding var projectType: ProjectType

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Label(L10n.parentProject, systemImage: "folder")
                Spacer(minLength: 12)

                Picker(L10n.parentProject, selection: $parentProjectId) {
                    Text(L10n.vaultRoot)
                        .tag(nil as UUID?)
                    ForEach(parentProjects) { project in
                        Text(project.projectName)
                            .tag(project.projectId as UUID?)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 220, alignment: .trailing)
            }
            .padding(12)

            Divider()

            HStack(spacing: 16) {
                Label(L10n.projectType, systemImage: "square.grid.2x2")
                Spacer(minLength: 12)

                if parentProjectId == nil {
                    Picker(L10n.projectType, selection: $projectType) {
                        ForEach(ProjectType.allCases, id: \.self) { type in
                            Text(L10n.projectTypeName(type))
                                .tag(type)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 220, alignment: .trailing)
                } else {
                    Label(L10n.subprojectTypeInheritanceHelp, systemImage: "arrow.triangle.branch")
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 220, minHeight: 36, alignment: .leading)
                }
            }
            .padding(12)
        }
        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.2))
        }
    }
}
