import SwiftUI

struct ProjectCatalogIconHoverHighlight: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .frame(width: 24, height: 24)
            .contentShape(.rect)
            .background(
                isEnabled && isHovered ? DahliaDesign.sidebarHighlightColor : .clear,
                in: RoundedRectangle(cornerRadius: DahliaDesign.Highlight.compactCornerRadius)
            )
            .onHover { isHovered = $0 }
    }
}

extension View {
    func projectCatalogIconHoverHighlight() -> some View {
        modifier(ProjectCatalogIconHoverHighlight())
    }
}
