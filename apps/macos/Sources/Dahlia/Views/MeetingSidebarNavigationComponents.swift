import SwiftUI

struct SidebarSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.subheadline)
            .foregroundStyle(DahliaDesign.sidebarSecondaryTextColor)
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
            .foregroundStyle(DahliaDesign.sidebarPrimaryTextColor)
            .dahliaSidebarHoverHighlight(isHovered: isHovered, isSelected: isSelected)
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .onHover { isHovered = $0 }
    }
}
