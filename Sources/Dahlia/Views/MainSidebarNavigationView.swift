import SwiftUI

struct MainSidebarNavigationView: View {
    @Binding var meetingSidebarDisplayMode: MeetingSidebarDisplayMode
    let onCreateMeeting: () -> Void
    let canCreateMeeting: Bool
    let canStartQuickRecording: Bool
    let onStartQuickRecording: () -> Void
    let isShowingUpcomingSchedule: Bool
    let onShowUpcomingSchedule: () -> Void
    let isShowingProjects: Bool
    let onShowProjects: () -> Void
    let canCreateProject: Bool
    let onCreateProject: () -> Void
    let isShowingUnprocessedRecordings: Bool
    let unprocessedRecordingCount: Int
    let onShowUnprocessedRecordings: () -> Void
    let showsCustomerIntelligence: Bool
    let onOpenCustomerIntelligence: () -> Void

    var body: some View {
        VStack(spacing: 2) {
            MainSidebarMeetingNavigationRow(
                canCreateMeeting: canCreateMeeting,
                canStartQuickRecording: canStartQuickRecording,
                onCreateMeeting: onCreateMeeting,
                onStartQuickRecording: onStartQuickRecording
            )

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

            if meetingSidebarDisplayMode == .chronological {
                MainSidebarProjectNavigationRow(
                    displayMode: $meetingSidebarDisplayMode,
                    isSelected: isShowingProjects,
                    canCreateProject: canCreateProject,
                    onOpen: onShowProjects,
                    onCreateProject: onCreateProject
                )
            }

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
        .padding(.vertical, DahliaDesign.sidebarNavigationVerticalPadding)
    }
}
