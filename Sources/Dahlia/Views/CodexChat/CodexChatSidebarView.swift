import SwiftUI

struct CodexChatSidebarView: View {
    @Bindable var coordinator: CodexChatCoordinator
    @Bindable var sidebarViewModel: SidebarViewModel
    @Binding var showsHistory: Bool
    @Binding var showsConfiguration: Bool
    let onOpenDetachedSession: (CodexChatSessionID) -> Void

    var body: some View {
        CodexChatView(
            session: coordinator.dockedSession,
            coordinator: coordinator,
            meetingReferences: sidebarViewModel.meetingReferences,
            meetingCatalogVaultID: sidebarViewModel.currentVault?.id,
            isMeetingCatalogLoaded: sidebarViewModel.isMeetingCatalogLoaded,
            showsHeader: false,
            showsHistory: $showsHistory,
            configurationPresentation: $showsConfiguration,
            onNewChat: coordinator.newDockedChat,
            onOpenHistory: openHistory
        )
        .task(id: sidebarViewModel.currentVault?.id) {
            sidebarViewModel.loadMeetingReferencesIfNeeded()
        }
    }

    private func openHistory(_ thread: CodexChatThreadSummary) {
        Task {
            let id = await coordinator.openHistoryThread(thread)
            if coordinator.detachedSessionIDs.contains(id) {
                onOpenDetachedSession(id)
            }
        }
    }
}
