import SwiftUI

struct ProjectCalendarNavigationControl: ViewModifier {
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .font(.callout)
            .foregroundStyle(.secondary)
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .contentShape(.rect)
            .background(
                isHovered ? DahliaDesign.contentHighlightColor : .clear,
                in: .rect(cornerRadius: DahliaDesign.Highlight.compactCornerRadius)
            )
            .onHover { isHovered = $0 }
    }
}

extension View {
    func projectCalendarNavigationControl() -> some View {
        modifier(ProjectCalendarNavigationControl())
    }
}
