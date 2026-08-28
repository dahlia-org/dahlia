import SwiftUI

struct CodexChatSidebarView: View {
    @Bindable var coordinator: CodexChatCoordinator
    @Bindable var sidebarViewModel: SidebarViewModel
    @Binding var showsHistory: Bool
    @Binding var showsConfiguration: Bool
    let isFullScreen: Bool
    var headerLeadingInset: CGFloat = 0
    let onShowFullScreen: (() -> Void)?
    let onPopOut: () -> Void
    let onOpenDetachedSession: (CodexChatSessionID) -> Void

    var body: some View {
        CodexChatView(
            session: coordinator.dockedSession,
            coordinator: coordinator,
            meetingReferences: sidebarViewModel.meetingReferences,
            meetingCatalogVaultID: sidebarViewModel.currentVault?.id,
            isMeetingCatalogLoaded: sidebarViewModel.isMeetingCatalogLoaded,
            showsHistory: $showsHistory,
            configurationPresentation: $showsConfiguration,
            onNewChat: startNewChat,
            onOpenHistory: openHistory,
            onShowFullScreen: onShowFullScreen,
            onPopOut: onPopOut,
            reservesSidebarToggle: !isFullScreen,
            reservesWindowControls: false,
            headerLeadingInset: headerLeadingInset,
            contentMaxWidth: isFullScreen ? DahliaDesign.mainContentMaxWidth : nil
        )
        .task(id: sidebarViewModel.currentVault?.id) {
            sidebarViewModel.loadMeetingReferencesIfNeeded()
        }
    }

    private func startNewChat() {
        showsConfiguration = false
        coordinator.newDockedChat(showDockedSidebar: !isFullScreen)
    }

    private func openHistory(_ thread: CodexChatThreadSummary) {
        Task {
            let id = await coordinator.openHistoryThread(thread, showDockedSidebar: !isFullScreen)
            if coordinator.detachedSessionIDs.contains(id) {
                onOpenDetachedSession(id)
            }
        }
    }
}
