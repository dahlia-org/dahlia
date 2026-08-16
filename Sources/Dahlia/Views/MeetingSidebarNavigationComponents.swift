import SwiftUI

struct SidebarSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }
}

struct SidebarNavigationRowModifier: ViewModifier {
    var isSelected = false
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(backgroundColor)
            }
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .onHover { isHovered = $0 }
    }

    private var backgroundColor: Color {
        if isSelected {
            return DahliaDesign.sidebarSelectionHighlightColor
        }
        return isHovered ? DahliaDesign.hoverHighlightColor : .clear
    }
}
