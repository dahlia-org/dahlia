import SwiftUI

struct ProjectContextSectionView: View {
    let vaultName: String
    let project: ProjectOverviewItem
    let parentName: String?
    let includedSubprojectCount: Int
    let hierarchyMeetingCount: Int

    var body: some View {
        Section(L10n.projectOverview) {
            LabeledContent(L10n.vault) {
                Label(vaultName, systemImage: "externaldrive")
                    .foregroundStyle(.primary)
            }

            LabeledContent(L10n.projectLocation) {
                Text(projectPath)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            }

            LabeledContent(L10n.parentProject) {
                Text(parentName ?? L10n.vaultRoot)
                    .foregroundStyle(.secondary)
            }

            LabeledContent(L10n.projectType) {
                Text(L10n.projectTypeName(project.effectiveProjectType))
                    .foregroundStyle(.primary)
            }

            LabeledContent(L10n.meetingsInThisProject) {
                Text(L10n.meetingCount(project.meetingCount))
                    .foregroundStyle(.secondary)
            }

            if includedSubprojectCount > 0 {
                LabeledContent(L10n.includedSubprojects) {
                    Text(L10n.includedSubprojectCount(includedSubprojectCount))
                        .foregroundStyle(.secondary)
                }

                LabeledContent(L10n.meetingsInHierarchy) {
                    Text(L10n.meetingCount(hierarchyMeetingCount))
                        .foregroundStyle(.secondary)
                }
            }

        }
    }

    private var projectPath: String {
        project.projectName
            .split(separator: "/")
            .map(String.init)
            .joined(separator: " › ")
    }
}
