import SwiftUI

struct MainSidebarNavigationView: View {
    let selectedTab: MainSidebarTab
    let onSelectTab: (MainSidebarTab) -> Void
    let onCreateMeeting: () -> Void
    let canCreateMeeting: Bool
    let canStartQuickRecording: Bool
    let onStartQuickRecording: () -> Void
    let canCreateProject: Bool
    let onCreateProject: () -> Void
    let onNewChat: () -> Void

    var body: some View {
        VStack(spacing: 2) {
            MainSidebarTabBar(selection: selectedTab, onSelect: onSelectTab)
                .padding(.horizontal, -6) // Line the button highlights up with the row highlights below.
                .padding(.bottom, 6)

            switch selectedTab {
            case .meetings:
                MainSidebarMeetingNavigationRow(
                    canCreateMeeting: canCreateMeeting,
                    canStartQuickRecording: canStartQuickRecording,
                    onCreateMeeting: onCreateMeeting,
                    onStartQuickRecording: onStartQuickRecording
                )

            case .projects:
                Button(action: onCreateProject) {
                    MainSidebarNavigationLabel(title: L10n.newProject, systemImage: "folder.badge.plus")
                }
                .buttonStyle(.plain)
                .disabled(!canCreateProject)
                .help(L10n.newProject)

            case .chat:
                Button(action: onNewChat) {
                    MainSidebarNavigationLabel(title: L10n.newChat, systemImage: "plus.message")
                }
                .buttonStyle(.plain)
                .help(L10n.newChat)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, DahliaDesign.sidebarNavigationVerticalPadding)
    }
}
