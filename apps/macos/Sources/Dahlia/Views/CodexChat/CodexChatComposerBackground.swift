import SwiftUI

struct CodexChatComposerBackground: View {
    let isDropTargeted: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: CodexChatDesign.composerCornerRadius)
            .fill(.background)
            .overlay {
                RoundedRectangle(cornerRadius: CodexChatDesign.composerCornerRadius)
                    .stroke(borderColor, lineWidth: isDropTargeted ? 2 : 1)
            }
    }

    private var borderColor: Color {
        isDropTargeted ? .accentColor : .secondary.opacity(0.3)
    }
}
