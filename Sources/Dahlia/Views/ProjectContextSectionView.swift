import SwiftUI

struct ProjectContextSectionView: View {
    let project: ProjectOverviewItem
    let includedSubprojectCount: Int
    let hierarchyMeetingCount: Int

    var body: some View {
        Section(L10n.projectOverview) {
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
}
