import AppKit
import SwiftUI

enum DahliaDesign {
    static let hoverHighlightColor = Color.gray.opacity(0.16)
    static let sidebarSelectionColor = Color.gray
    static let sidebarSelectionHighlightColor = sidebarSelectionColor.opacity(0.32)
    static let sidebarPrimaryTextColor = adaptiveSidebarColor(
        light: NSColor(srgbRed: 58 / 255, green: 60 / 255, blue: 62 / 255, alpha: 1),
        dark: NSColor(srgbRed: 198 / 255, green: 197 / 255, blue: 198 / 255, alpha: 1)
    )
    static let sidebarSecondaryTextColor = adaptiveSidebarColor(
        light: NSColor(srgbRed: 165 / 255, green: 165 / 255, blue: 165 / 255, alpha: 1),
        dark: NSColor(srgbRed: 135 / 255, green: 129 / 255, blue: 129 / 255, alpha: 1)
    )
    static let sidebarRowVerticalPadding: CGFloat = 3
    static let sidebarNavigationVerticalPadding: CGFloat = 8

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
    static let detailTopPadding = windowHeaderHeight + sidebarNavigationVerticalPadding
    static let tabContentInset: CGFloat = 16

    private static func adaptiveSidebarColor(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
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
    func dahliaSidebarHoverHighlight(isHovered: Bool, isSelected: Bool = false) -> some View {
        let color = if isSelected {
            DahliaDesign.sidebarSelectionHighlightColor
        } else if isHovered {
            DahliaDesign.hoverHighlightColor
        } else {
            Color.clear
        }

        return background {
            RoundedRectangle(cornerRadius: 6)
                .fill(color)
                .padding(.vertical, -4)
                .padding(.horizontal, -6)
        }
    }

    func dahliaChipSurface(isHovered: Bool = false, tint: Color? = nil) -> some View {
        modifier(DahliaChipSurface(isHovered: isHovered, tint: tint))
    }
}
