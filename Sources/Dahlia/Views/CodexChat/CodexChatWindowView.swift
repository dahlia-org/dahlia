import SwiftUI

struct CodexChatWindowView: View {
    @Bindable var coordinator: CodexChatCoordinator
    @Bindable var sidebarViewModel: SidebarViewModel
    @State private var sessionID: CodexChatSessionID

    init(
        coordinator: CodexChatCoordinator,
        sidebarViewModel: SidebarViewModel,
        sessionID: CodexChatSessionID
    ) {
        self.coordinator = coordinator
        self.sidebarViewModel = sidebarViewModel
        _sessionID = State(initialValue: sessionID)
    }

    var body: some View {
        Group {
            if let session = coordinator.session(for: sessionID) {
                CodexChatView(
                    session: session,
                    coordinator: coordinator,
                    meetings: sidebarViewModel.allMeetings,
                    meetingCatalogVaultID: sidebarViewModel.currentVault?.id,
                    isMeetingCatalogLoaded: sidebarViewModel.isMeetingCatalogLoaded,
                    allowsPopOut: false,
                    onNewChat: startNewChat,
                    onPopOut: {},
                    onHide: nil,
                    onOpenHistory: openHistory
                )
            } else {
                ProgressView()
                    .task { coordinator.ensureDetachedSession(id: sessionID) }
            }
        }
        .frame(minWidth: 420, minHeight: 360)
        .onDisappear {
            coordinator.detachedWindowClosed(sessionID: sessionID)
        }
    }

    private func startNewChat() {
        sessionID = coordinator.newDetachedChat(replacing: sessionID)
    }

    private func openHistory(_ thread: CodexChatThreadSummary) {
        Task {
            let id = await coordinator.openHistoryThreadInDetachedWindow(thread)
            guard id != sessionID else { return }
            coordinator.detachedWindowClosed(sessionID: sessionID)
            sessionID = id
        }
    }
}
