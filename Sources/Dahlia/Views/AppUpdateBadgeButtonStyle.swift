import SwiftUI

struct AppUpdateBadgeButtonStyle: ButtonStyle {
    let isHovered: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(.white)
            .background(backgroundColor(isPressed: configuration.isPressed), in: Capsule())
            .contentShape(Capsule())
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        if isPressed {
            return Color.accentColor.opacity(0.7)
        }
        if isHovered {
            return Color.accentColor.opacity(0.85)
        }
        return Color.accentColor
    }
}
