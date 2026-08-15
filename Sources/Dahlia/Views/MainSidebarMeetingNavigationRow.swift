import SwiftUI

struct MainSidebarMeetingNavigationRow: View {
    let canCreateMeeting: Bool
    let canStartQuickRecording: Bool
    let onCreateMeeting: () -> Void
    let onStartQuickRecording: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onCreateMeeting) {
                Label(L10n.createNewMeeting, systemImage: "square.and.pencil")
                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canCreateMeeting)
            .help(L10n.createNewMeeting)

            MainSidebarNavigationAccessoryButton(
                title: L10n.quickRecording,
                systemImage: "bolt.circle",
                isEnabled: canStartQuickRecording,
                action: onStartQuickRecording
            )
        }
        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
        .modifier(SidebarNavigationRowModifier(isSelected: false))
    }
}
