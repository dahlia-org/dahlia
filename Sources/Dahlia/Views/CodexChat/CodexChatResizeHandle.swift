import SwiftUI

struct CodexChatResizeHandle: View {
    @Binding var layout: CodexChatFloatingLayout
    let availableSize: CGSize
    let edge: CodexChatResizeEdge

    @State private var resizeStart: CodexChatFloatingLayout?
    @State private var isHovering = false

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged(resize)
                    .onEnded(endResize)
            )
            .onHover(perform: updateHover)
            .onDisappear(perform: resetCursor)
    }

    private func resize(_ value: DragGesture.Value) {
        if resizeStart == nil {
            resizeStart = layout
            edge.cursor.set()
        }
        guard var resized = resizeStart else { return }
        resized.resize(from: edge, translation: value.translation, availableSize: availableSize)
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            layout = resized
        }
    }

    private func endResize(_: DragGesture.Value) {
        resizeStart = nil
        (isHovering ? edge.cursor : .arrow).set()
    }

    private func updateHover(_ hovering: Bool) {
        guard hovering != isHovering else { return }
        isHovering = hovering
        if hovering {
            edge.cursor.set()
        } else if resizeStart == nil {
            NSCursor.arrow.set()
        }
    }

    private func resetCursor() {
        if isHovering || resizeStart != nil {
            NSCursor.arrow.set()
        }
    }
}
