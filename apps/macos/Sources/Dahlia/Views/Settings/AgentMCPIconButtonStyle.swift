import SwiftUI

struct AgentMCPIconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.dahliaSecondary)
            .frame(width: 24, height: 24)
            .background(
                Color.primary.opacity(configuration.isPressed ? 0.14 : isHovered ? 0.10 : 0.06),
                in: .circle
            )
            .overlay {
                Circle()
                    .strokeBorder(Color.primary.opacity(0.10))
            }
            .contentShape(.circle)
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { isHovered = $0 }
    }
}
