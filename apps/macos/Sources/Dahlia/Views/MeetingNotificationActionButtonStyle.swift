import SwiftUI

struct MeetingNotificationActionButtonStyle: ButtonStyle {
    let tint: Color
    let isHovered: Bool

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16)
        return configuration.label
            .font(.title2)
            .bold()
            .foregroundStyle(.white)
            .padding(.horizontal, 28)
            .frame(minHeight: 64)
            .background(
                tint.opacity(backgroundOpacity(isPressed: configuration.isPressed)),
                in: shape
            )
            .overlay {
                shape.strokeBorder(.white.opacity(isHovered ? 0.42 : 0.14), lineWidth: 1)
            }
            .shadow(color: tint.opacity(isHovered ? 0.28 : 0), radius: 10, y: 4)
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }

    private func backgroundOpacity(isPressed: Bool) -> Double {
        if isPressed {
            return 0.72
        }
        return isHovered ? 0.88 : 1
    }
}
