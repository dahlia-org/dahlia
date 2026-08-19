import SwiftUI

extension View {
    func codexChatPanelStyle() -> some View {
        fixedSize()
            .background(.background, in: RoundedRectangle(cornerRadius: CodexChatDesign.panelCornerRadius))
            .clipShape(RoundedRectangle(cornerRadius: CodexChatDesign.panelCornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: CodexChatDesign.panelCornerRadius)
                    .stroke(.separator.opacity(0.65), lineWidth: 1)
            }
            .containerShape(.rect(cornerRadius: CodexChatDesign.panelCornerRadius))
            .shadow(color: .black.opacity(0.16), radius: 18, y: 8)
            .accessibilityElement(children: .contain)
    }
}
