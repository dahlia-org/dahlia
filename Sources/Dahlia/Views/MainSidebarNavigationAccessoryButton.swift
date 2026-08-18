import SwiftUI

struct MainSidebarNavigationAccessoryButton: View {
    let title: String
    let systemImage: String
    let isEnabled: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(title, systemImage: systemImage, action: action)
            .labelStyle(.iconOnly)
            .dahliaFixedSymbol()
            .buttonStyle(.plain)
            .foregroundStyle(foregroundColor)
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
            .disabled(!isEnabled)
            .help(title)
            .onHover { isHovered = $0 }
    }

    private var foregroundColor: Color {
        guard isEnabled else { return .secondary.opacity(0.35) }
        return isHovered ? .primary : .secondary.opacity(0.65)
    }
}
