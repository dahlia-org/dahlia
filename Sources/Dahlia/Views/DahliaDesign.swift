import SwiftUI

enum DahliaDesign {
    static let hoverHighlightColor = Color.gray.opacity(0.16)
    static let sidebarSelectionColor = Color.gray
    static let sidebarSelectionHighlightColor = sidebarSelectionColor.opacity(0.32)

    static let windowHeaderHeight: CGFloat = 32
    static let windowHeaderHorizontalPadding: CGFloat = 12
    static let windowControlsLeadingInset: CGFloat = 68
    static let windowHeaderControlSize: CGFloat = 28
    static let windowHeaderGroupSpacing: CGFloat = 4
    static let windowHeaderHelpHorizontalInset: CGFloat = 8

    static let readingMaxWidth: CGFloat = 720
    static let readingHorizontalPadding: CGFloat = 20

    static let paragraphLineSpacing: CGFloat = 3
    static let listItemSpacing: CGFloat = 6
    static let blockSpacing: CGFloat = 14
    static let sectionHeadingTopPadding: CGFloat = 12

    static let chipHorizontalPadding: CGFloat = 8
    static let chipVerticalPadding: CGFloat = 3.5
    static let chipStaticOpacity = 0.055
    static let chipTintOpacity = 0.10
    static let chipSpacing: CGFloat = 6
    static let chipRowSpacing: CGFloat = 7

    static let timestampChipHorizontalPadding: CGFloat = 5
    static let timestampChipVerticalPadding: CGFloat = 1.5
    static let timestampChipBackgroundOpacity = 0.05

    static let tabHorizontalPadding: CGFloat = 12
    static let tabVerticalPadding: CGFloat = 7
    static let tabIndicatorHeight: CGFloat = 2

    static let detailHorizontalPadding: CGFloat = 24
    static let detailTopPadding: CGFloat = 20
    static let tabContentInset: CGFloat = 16
}

private struct DahliaChipSurface: ViewModifier {
    let isHovered: Bool
    let tint: Color?

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, DahliaDesign.chipHorizontalPadding)
            .padding(.vertical, DahliaDesign.chipVerticalPadding)
            .background {
                Capsule()
                    .fill(surfaceColor)
            }
    }

    private var surfaceColor: Color {
        if isHovered {
            return DahliaDesign.hoverHighlightColor
        }
        if let tint {
            return tint.opacity(DahliaDesign.chipTintOpacity)
        }
        return Color.primary.opacity(DahliaDesign.chipStaticOpacity)
    }
}

extension View {
    func dahliaChipSurface(isHovered: Bool = false, tint: Color? = nil) -> some View {
        modifier(DahliaChipSurface(isHovered: isHovered, tint: tint))
    }
}
