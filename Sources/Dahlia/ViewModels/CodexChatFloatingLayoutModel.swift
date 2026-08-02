import SwiftUI

/// フローティングチャットの位置とサイズを保持する。
///
/// ドラッグ中のマウスイベントごとに更新されるため、状態を `CodexChatFloatingView` の `@State` ではなく
/// この Observable に置き、再評価をジオメトリを読む小さなコンテナビューだけに限定する。
@MainActor
@Observable
final class CodexChatFloatingLayoutModel {
    var layout: CodexChatFloatingLayout
    var dragTranslation = CGSize.zero

    init(dockSide: CodexChatDockSide) {
        layout = CodexChatFloatingLayout(dockSide: dockSide)
    }

    func updateDragging(_ translation: CGSize) {
        withoutAnimation { dragTranslation = translation }
    }

    /// ドラッグを確定し、ウィンドウ中心に近い側へドックさせる。
    func finishDragging(_ translation: CGSize, availableSize: CGSize, animated: Bool) {
        let origin = layout.origin(in: availableSize, dragTranslation: translation)
        let horizontalCenter = origin.x + layout.size.width / 2
        guard animated else {
            snap(horizontalCenter: horizontalCenter, availableWidth: availableSize.width)
            return
        }
        withAnimation(.snappy(duration: 0.28)) {
            snap(horizontalCenter: horizontalCenter, availableWidth: availableSize.width)
        }
    }

    func resize(
        from edge: CodexChatResizeEdge,
        start: CodexChatFloatingLayout,
        translation: CGSize,
        availableSize: CGSize
    ) {
        var resized = start
        resized.resize(from: edge, translation: translation, availableSize: availableSize)
        withoutAnimation { layout = resized }
    }

    func clamp(to availableSize: CGSize) {
        layout.clamp(to: availableSize)
    }

    private func snap(horizontalCenter: CGFloat, availableWidth: CGFloat) {
        layout.snap(horizontalCenter: horizontalCenter, availableWidth: availableWidth)
        dragTranslation = .zero
    }

    private func withoutAnimation(_ body: () -> Void) {
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction, body)
    }
}
