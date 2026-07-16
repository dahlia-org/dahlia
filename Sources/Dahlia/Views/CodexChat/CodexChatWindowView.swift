import SwiftUI

struct CodexChatWindowView: View {
    @Bindable var coordinator: CodexChatCoordinator
    @Bindable var sidebarViewModel: SidebarViewModel
    let sessionID: CodexChatSessionID

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if let session = coordinator.session(for: sessionID) {
                CodexChatView(
                    session: session,
                    coordinator: coordinator,
                    meetings: sidebarViewModel.allMeetings,
                    meetingCatalogVaultID: sidebarViewModel.currentVault?.id,
                    allowsPopOut: false,
                    onNewChat: openNewWindow,
                    onPopOut: {},
                    onHide: dismissWindow,
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

    private func openNewWindow() {
        let id = coordinator.newDetachedChat()
        openWindow(id: WindowID.codexChat, value: id)
    }

    private func dismissWindow() {
        NSApp.keyWindow?.performClose(nil)
    }

    private func openHistory(_ thread: CodexChatThreadSummary) {
        Task {
            let id = await coordinator.openHistoryThreadInDetachedWindow(thread)
            guard id != sessionID else { return }
            dismissWindow()
            openWindow(id: WindowID.codexChat, value: id)
        }
    }
}
