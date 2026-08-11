import SwiftUI

extension View {
    func codexChatPanelStyle() -> some View {
        fixedSize()
            .background(.background, in: RoundedRectangle(cornerRadius: 18))
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .stroke(.separator.opacity(0.65), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.16), radius: 18, y: 8)
            .accessibilityElement(children: .contain)
    }
}
