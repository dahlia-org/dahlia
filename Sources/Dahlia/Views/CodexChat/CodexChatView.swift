import SwiftUI

struct CodexChatView: View {
    @Bindable var session: CodexChatSessionModel
    @Bindable var coordinator: CodexChatCoordinator
    let allowsPopOut: Bool
    let onNewChat: () -> Void
    let onPopOut: () -> Void
    let onHide: () -> Void
    let onOpenHistory: (CodexChatThreadSummary) -> Void
    var onHeaderDragChanged: ((CGSize) -> Void)?
    var onHeaderDragEnded: ((CGSize) -> Void)?
    @State private var showsHistory = false

    var body: some View {
        VStack(spacing: 0) {
            CodexChatHeader(
                title: session.displayTitle,
                showsHistory: showsHistory,
                hasConversation: !session.messages.isEmpty,
                allowsPopOut: allowsPopOut,
                onBack: hideHistory,
                onShowHistory: showHistory,
                onNewChat: startNewChat,
                onPopOut: onPopOut,
                onHide: onHide,
                onDragChanged: onHeaderDragChanged,
                onDragEnded: onHeaderDragEnded
            )

            if showsHistory {
                CodexChatHistoryView(
                    threads: coordinator.history,
                    hasMore: coordinator.historyCursor != nil,
                    isLoading: coordinator.isLoadingHistory,
                    onNewChat: startNewChat,
                    onOpenThread: openHistoryThread,
                    onLoadMore: loadMoreHistory
                )
            } else if session.messages.isEmpty {
                CodexChatEmptyStateView(
                    recentThreads: Array(coordinator.history.prefix(3)),
                    onOpenThread: openHistoryThread,
                    onShowAll: showHistory
                )
            } else {
                CodexChatConversationView(messages: session.messages)
            }

            if let errorMessage = session.errorMessage ?? coordinator.historyError {
                CodexChatErrorView(
                    message: errorMessage,
                    canRetryTurn: session.lastSubmittedText != nil,
                    onRetryTurn: session.retry,
                    onRetryConnection: retryConnection
                )
            }

            CodexChatComposer(session: session)
                .padding(.horizontal, CodexChatDesign.composerHorizontalPadding)
                .padding(.bottom, CodexChatDesign.composerBottomPadding)
        }
        .background(.background)
        .task { await prepare() }
    }

    private func prepare() async {
        await session.restore()
        if coordinator.history.isEmpty {
            await coordinator.refreshHistory()
        }
    }

    private func showHistory() {
        showsHistory = true
        Task { await coordinator.refreshHistory() }
    }

    private func hideHistory() {
        showsHistory = false
    }

    private func startNewChat() {
        showsHistory = false
        onNewChat()
    }

    private func openHistoryThread(_ thread: CodexChatThreadSummary) {
        showsHistory = false
        onOpenHistory(thread)
    }

    private func loadMoreHistory() {
        Task { await coordinator.loadMoreHistory() }
    }

    private func retryConnection() {
        Task { await session.prepare(forceRefresh: true) }
    }
}
