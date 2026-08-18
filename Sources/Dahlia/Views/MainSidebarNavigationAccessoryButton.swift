import SwiftUI

struct MainSidebarNavigationAccessoryButton: View {
    let title: String
    let systemImage: String
    let isEnabled: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        DahliaWindowHeaderIconButton(
            label: title,
            systemImage: systemImage,
            showsHoverHighlight: false,
            presentsHelpInContainerOverlay: true,
            action: action
        )
        .foregroundStyle(foregroundColor)
        .disabled(!isEnabled)
        .onHover { isHovered = $0 }
    }

    private var foregroundColor: Color {
        guard isEnabled else { return .secondary.opacity(0.35) }
        return isHovered ? .primary : .secondary.opacity(0.65)
    }
}
