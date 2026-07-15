import SwiftUI

struct CodexChatResizeHandle: View {
    @Binding var layout: CodexChatFloatingLayout
    let availableSize: CGSize

    @State private var resizeStart: CodexChatFloatingLayout?

    var body: some View {
        Color.clear
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged(resize)
                    .onEnded { _ in resizeStart = nil }
            )
            .accessibilityLabel(L10n.resize)
    }

    private func resize(_ value: DragGesture.Value) {
        if resizeStart == nil {
            resizeStart = layout
        }
        guard var resized = resizeStart else { return }
        resized.resize(translation: value.translation, availableSize: availableSize)
        layout = resized
    }
}
