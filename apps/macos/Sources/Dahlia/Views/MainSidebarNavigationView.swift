import SwiftUI

struct MainSidebarNavigationView: View {
    let isShowingUpcomingSchedule: Bool
    let onShowUpcomingSchedule: () -> Void
    let isShowingProjectManagement: Bool
    let onShowProjectManagement: () -> Void
    let isShowingUnprocessedRecordings: Bool
    let unprocessedRecordingCount: Int
    let onShowUnprocessedRecordings: () -> Void
    let showsCustomerIntelligence: Bool
    let onOpenCustomerIntelligence: () -> Void

    var body: some View {
        VStack(spacing: 2) {
            Button(action: onShowUpcomingSchedule) {
                MainSidebarNavigationLabel(
                    title: L10n.calendarScheduleTitle,
                    systemImage: "calendar",
                    isSelected: isShowingUpcomingSchedule
                )
            }
            .buttonStyle(.plain)
            .help(L10n.showUpcomingSchedule)
            .accessibilityAddTraits(isShowingUpcomingSchedule ? .isSelected : [])

            Button(action: onShowProjectManagement) {
                MainSidebarNavigationLabel(
                    title: L10n.projectManagement,
                    systemImage: "folder",
                    isSelected: isShowingProjectManagement
                )
            }
            .buttonStyle(.plain)
            .help(L10n.manageProjects)
            .accessibilityAddTraits(isShowingProjectManagement ? .isSelected : [])

            if showsCustomerIntelligence {
                Button(action: onOpenCustomerIntelligence) {
                    MainSidebarNavigationLabel(
                        title: L10n.customerIntelligence,
                        systemImage: "building.2"
                    )
                }
                .buttonStyle(.plain)
                .help(L10n.openOrganizationWorkspace)
            }

            Button(action: onShowUnprocessedRecordings) {
                MainSidebarNavigationLabel(
                    title: L10n.unprocessedRecordings,
                    systemImage: "waveform.badge.exclamationmark",
                    badgeCount: unprocessedRecordingCount,
                    isSelected: isShowingUnprocessedRecordings
                )
            }
            .buttonStyle(.plain)
            .help(L10n.unprocessedRecordings)
            .accessibilityAddTraits(isShowingUnprocessedRecordings ? .isSelected : [])
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}
