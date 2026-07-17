import SwiftUI

struct ProjectContextSectionView: View {
    let vaultName: String
    let project: ProjectOverviewItem
    let includedSubprojectCount: Int
    let hierarchyMeetingCount: Int

    var body: some View {
        Section(L10n.projectOverview) {
            LabeledContent(L10n.vault) {
                Label(vaultName, systemImage: "externaldrive")
            }

            LabeledContent(L10n.projectLocation) {
                Text(projectPath)
                    .textSelection(.enabled)
            }

            LabeledContent(L10n.meetingsInThisProject) {
                Text(L10n.meetingCount(project.meetingCount))
            }

            if includedSubprojectCount > 0 {
                LabeledContent(L10n.includedSubprojects) {
                    Text(L10n.includedSubprojectCount(includedSubprojectCount))
                }

                LabeledContent(L10n.meetingsInHierarchy) {
                    Text(L10n.meetingCount(hierarchyMeetingCount))
                }
            }

            if project.missingOnDisk {
                Label(L10n.missingOnDisk, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
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
