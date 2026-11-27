import SwiftUI

struct CodexChatSidebarView: View {
    @AppStorage(ContentWidth.chatUserDefaultsKey) private var chatContentWidth = ContentWidth.chatDefault
    @Bindable var coordinator: CodexChatCoordinator
    @Bindable var sidebarViewModel: SidebarViewModel
    @Binding var showsHistory: Bool
    @Binding var showsConfiguration: Bool
    let isFullScreen: Bool
    var headerLeadingInset: CGFloat = 0
    let onShowFullScreen: (() -> Void)?
    let onOpenDetachedSession: (CodexChatSessionID) -> Void
    /// The full-screen chat leaves room for the window's side panel toggle while the agent's panel is hidden.
    var reservesPanelToggle = false
    /// The agent whose thread this is.
    var agent: AgentRecord?

    var body: some View {
        CodexChatView(
            session: coordinator.dockedSession,
            coordinator: coordinator,
            sidebarViewModel: sidebarViewModel,
            meetingReferences: sidebarViewModel.meetingReferences,
            meetingCatalogWorkspaceID: sidebarViewModel.currentWorkspace?.id,
            isMeetingCatalogLoaded: sidebarViewModel.isMeetingCatalogLoaded,
            showsHistory: $showsHistory,
            configurationPresentation: isFullScreen ? nil : $showsConfiguration,
            onNewChat: startNewChat,
            onOpenHistory: openHistory,
            onShowFullScreen: onShowFullScreen,
            reservesSidebarToggle: !isFullScreen || reservesPanelToggle,
            reservesWindowControls: false,
            headerLeadingInset: headerLeadingInset,
            contentMaxWidth: isFullScreen ? chatContentWidth.maxWidth : nil,
            isSidePanel: !isFullScreen,
            agent: agent
        )
        .task(id: sidebarViewModel.currentWorkspace?.id) {
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
