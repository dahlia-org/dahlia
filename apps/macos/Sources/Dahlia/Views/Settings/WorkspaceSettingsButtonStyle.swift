import SwiftUI

struct WorkspaceSettingsButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Color.primary.opacity(isEnabled ? (configuration.isPressed ? 0.14 : isHovered ? 0.10 : 0) : 0),
                in: .rect(cornerRadius: DahliaDesign.Button.cornerRadius)
            )
            .onHover { isHovered = $0 }
    }
}
