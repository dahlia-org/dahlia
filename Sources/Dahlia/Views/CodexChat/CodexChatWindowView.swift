import SwiftUI

struct CodexChatWindowView: View {
    @Bindable var coordinator: CodexChatCoordinator
    @Bindable var sidebarViewModel: SidebarViewModel
    @State private var sessionID: CodexChatSessionID
    @State private var showsHistory = false

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
                    meetingReferences: sidebarViewModel.meetingReferences,
                    meetingCatalogVaultID: sidebarViewModel.currentVault?.id,
                    isMeetingCatalogLoaded: sidebarViewModel.isMeetingCatalogLoaded,
                    showsHistory: $showsHistory,
                    configurationPresentation: nil,
                    onNewChat: startNewChat,
                    onOpenHistory: openHistory,
                    onPopOut: nil,
                    reservesSidebarToggle: false,
                    reservesWindowControls: true
                )
            } else {
                VStack(spacing: 0) {
                    DahliaWindowHeader(reservesWindowControls: true) {
                        Spacer()
                    }
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .task { coordinator.ensureDetachedSession(id: sessionID) }
            }
        }
        .frame(minWidth: 420, minHeight: 360)
        .task(id: sidebarViewModel.currentVault?.id) {
            sidebarViewModel.loadMeetingReferencesIfNeeded()
        }
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
