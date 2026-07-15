import SwiftUI

struct CodexChatFloatingView: View {
    @Bindable var coordinator: CodexChatCoordinator
    let onPopOut: (CodexChatSessionID) -> Void
    let onOpenDetachedSession: (CodexChatSessionID) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var layout: CodexChatFloatingLayout
    @State private var dragTranslation = CGSize.zero

    init(
        coordinator: CodexChatCoordinator,
        onPopOut: @escaping (CodexChatSessionID) -> Void,
        onOpenDetachedSession: @escaping (CodexChatSessionID) -> Void
    ) {
        self.coordinator = coordinator
        self.onPopOut = onPopOut
        self.onOpenDetachedSession = onOpenDetachedSession
        _layout = State(initialValue: CodexChatFloatingLayout(dockSide: AppSettings.shared.codexChatDockSide))
    }

    var body: some View {
        GeometryReader { geometry in
            let origin = layout.origin(in: geometry.size, dragTranslation: dragTranslation)
            ZStack(alignment: .topLeading) {
                CodexChatView(
                    session: coordinator.floatingSession,
                    coordinator: coordinator,
                    allowsPopOut: true,
                    onNewChat: coordinator.newFloatingChat,
                    onPopOut: popOut,
                    onHide: coordinator.hideFloating,
                    onOpenHistory: openHistory,
                    onHeaderDragChanged: { dragTranslation = $0 },
                    onHeaderDragEnded: { finishDragging($0, availableSize: geometry.size) }
                )
                .frame(width: layout.size.width, height: layout.size.height)
                .clipShape(RoundedRectangle(cornerRadius: 24))
                .overlay {
                    RoundedRectangle(cornerRadius: 24)
                        .stroke(.separator.opacity(0.6), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.18), radius: 22, y: 8)
                .position(
                    x: origin.x + layout.size.width / 2,
                    y: origin.y + layout.size.height / 2
                )

                CodexChatResizeHandle(layout: $layout, availableSize: geometry.size)
                    .position(
                        x: layout.dockSide == .right ? origin.x + 12 : origin.x + layout.size.width - 12,
                        y: origin.y + 12
                    )
            }
            .onChange(of: geometry.size) {
                layout.clamp(to: geometry.size)
            }
        }
    }

    private func finishDragging(_ translation: CGSize, availableSize: CGSize) {
        let origin = layout.origin(in: availableSize, dragTranslation: translation)
        let snap = {
            layout.snap(horizontalCenter: origin.x + layout.size.width / 2, availableWidth: availableSize.width)
            dragTranslation = .zero
        }
        if reduceMotion {
            snap()
        } else {
            withAnimation(.snappy(duration: 0.28), snap)
        }
        AppSettings.shared.codexChatDockSide = layout.dockSide
    }

    private func popOut() {
        onPopOut(coordinator.popOutFloating())
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
