import SwiftUI

struct CodexChatFloatingView: View {
    @Bindable var coordinator: CodexChatCoordinator
    @Bindable var sidebarViewModel: SidebarViewModel
    let onPopOut: (CodexChatSessionID) -> Void
    let onOpenDetachedSession: (CodexChatSessionID) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var layoutModel: CodexChatFloatingLayoutModel

    init(
        coordinator: CodexChatCoordinator,
        sidebarViewModel: SidebarViewModel,
        onPopOut: @escaping (CodexChatSessionID) -> Void,
        onOpenDetachedSession: @escaping (CodexChatSessionID) -> Void
    ) {
        self.coordinator = coordinator
        self.sidebarViewModel = sidebarViewModel
        self.onPopOut = onPopOut
        self.onOpenDetachedSession = onOpenDetachedSession
        _layoutModel = State(
            initialValue: CodexChatFloatingLayoutModel(dockSide: AppSettings.shared.codexChatDockSide)
        )
    }

    // ドラッグ中に更新されるジオメトリは `CodexChatFloatingContainer` だけが読む。
    // ここでレイアウトを読むとマウスイベントごとにチャット本体まで再評価される。
    var body: some View {
        GeometryReader { geometry in
            CodexChatFloatingContainer(
                layoutModel: layoutModel,
                availableSize: geometry.size,
                content: CodexChatView(
                    session: coordinator.floatingSession,
                    coordinator: coordinator,
                    meetingReferences: sidebarViewModel.meetingReferences,
                    meetingCatalogVaultID: sidebarViewModel.currentVault?.id,
                    isMeetingCatalogLoaded: sidebarViewModel.isMeetingCatalogLoaded,
                    allowsPopOut: true,
                    onNewChat: coordinator.newFloatingChat,
                    onPopOut: popOut,
                    onHide: coordinator.hideFloating,
                    onOpenHistory: openHistory,
                    onHeaderDragChanged: layoutModel.updateDragging,
                    onHeaderDragEnded: { finishDragging($0, availableSize: geometry.size) }
                )
            )
            .onChange(of: geometry.size) {
                layoutModel.clamp(to: geometry.size)
            }
            .task(id: sidebarViewModel.currentVault?.id) {
                sidebarViewModel.loadMeetingReferencesIfNeeded()
            }
        }
    }

    private func finishDragging(_ translation: CGSize, availableSize: CGSize) {
        layoutModel.finishDragging(translation, availableSize: availableSize, animated: !reduceMotion)
        AppSettings.shared.codexChatDockSide = layoutModel.layout.dockSide
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

/// ドラッグ中の位置とサイズだけを反映する薄いコンテナ。
///
/// `content` は組み立て済みのビュー値として受け取るため、ここが再評価されてもチャット本体の body は再評価されない。
private struct CodexChatFloatingContainer<Content: View>: View {
    let layoutModel: CodexChatFloatingLayoutModel
    let availableSize: CGSize
    let content: Content

    var body: some View {
        let layout = layoutModel.layout
        let origin = layout.origin(in: availableSize, dragTranslation: layoutModel.dragTranslation)
        let restingOrigin = layout.origin(in: availableSize)
        let interactionSize = CodexChatResizeHandles.interactionSize(for: layout.size)
        ZStack {
            content
                .frame(width: layout.size.width, height: layout.size.height)
                .clipShape(.rect(cornerRadius: 24))
                .contentShape(.interaction, .rect(cornerRadius: 24))
                .overlay {
                    RoundedRectangle(cornerRadius: 24)
                        .stroke(.separator.opacity(0.6), lineWidth: 1)
                }
                // 影はチャット本体ではなく同じ形の背景シェイプに掛ける。
                // 本体に掛けるとリサイズのたびにチャット全体をオフスクリーンにラスタライズし直すことになる。
                .background {
                    RoundedRectangle(cornerRadius: 24)
                        .fill(.background)
                        .shadow(color: .black.opacity(0.18), radius: 22, y: 8)
                }

            CodexChatResizeHandles(layoutModel: layoutModel, availableSize: availableSize)
        }
        .frame(width: interactionSize.width, height: interactionSize.height)
        .position(
            x: restingOrigin.x + layout.size.width / 2,
            y: restingOrigin.y + layout.size.height / 2
        )
        .offset(x: origin.x - restingOrigin.x)
    }
}
