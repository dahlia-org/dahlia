import SwiftUI

struct CodexChatWindowView: View {
    @Bindable var coordinator: CodexChatCoordinator
    let sessionID: CodexChatSessionID

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        CodexChatView(
            session: coordinator.session(for: sessionID),
            coordinator: coordinator,
            allowsPopOut: false,
            onNewChat: openNewWindow,
            onPopOut: {},
            onHide: dismissWindow,
            onOpenHistory: openHistory
        )
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
            let id = await coordinator.openHistoryThread(thread)
            if coordinator.detachedSessionIDs.contains(id) {
                openWindow(id: WindowID.codexChat, value: id)
            }
        }
    }
}
