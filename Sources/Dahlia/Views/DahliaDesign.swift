import AppKit
import SwiftUI

enum DahliaDesign {
    static let sidebarHighlightColor = Color.primary.opacity(0.10)
    static let contentHighlightColor = Color.primary.opacity(0.05)
    static let chipHoverColor = Color.primary.opacity(0.10)
    static let primaryTextNSColor = adaptiveTextColor(
        light: NSColor(srgbRed: 26 / 255, green: 28 / 255, blue: 31 / 255, alpha: 1),
        dark: NSColor(srgbRed: 223 / 255, green: 223 / 255, blue: 223 / 255, alpha: 1),
        increasedContrast: .labelColor
    )
    static let secondaryTextNSColor = adaptiveTextColor(
        light: NSColor(srgbRed: 117 / 255, green: 118 / 255, blue: 119 / 255, alpha: 1),
        dark: NSColor(srgbRed: 180 / 255, green: 180 / 255, blue: 180 / 255, alpha: 1),
        increasedContrast: .secondaryLabelColor
    )
    static let optionalTextNSColor = adaptiveTextColor(
        light: NSColor(srgbRed: 145 / 255, green: 145 / 255, blue: 147 / 255, alpha: 1),
        dark: NSColor(srgbRed: 144 / 255, green: 144 / 255, blue: 144 / 255, alpha: 1),
        increasedContrast: .tertiaryLabelColor
    )
    static let primaryTextColor = Color(nsColor: primaryTextNSColor)
    static let secondaryTextColor = Color(nsColor: secondaryTextNSColor)
    static let optionalTextColor = Color(nsColor: optionalTextNSColor)
    static let sidebarPrimaryTextColor = Color(nsColor: adaptiveTextColor(
        light: NSColor(srgbRed: 58 / 255, green: 60 / 255, blue: 62 / 255, alpha: 1),
        dark: NSColor(srgbRed: 198 / 255, green: 197 / 255, blue: 198 / 255, alpha: 1),
        increasedContrast: .labelColor
    ))
    static let sidebarSecondaryTextColor = Color(nsColor: adaptiveTextColor(
        light: NSColor(srgbRed: 165 / 255, green: 165 / 255, blue: 165 / 255, alpha: 1),
        dark: NSColor(srgbRed: 135 / 255, green: 129 / 255, blue: 129 / 255, alpha: 1),
        increasedContrast: .secondaryLabelColor
    ))
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

    private static func adaptiveTextColor(
        light: NSColor,
        dark: NSColor,
        increasedContrast: NSColor
    ) -> NSColor {
        NSColor(name: nil) { appearance in
            switch appearance.bestMatch(from: [
                .accessibilityHighContrastDarkAqua,
                .accessibilityHighContrastAqua,
                .darkAqua,
                .aqua,
            ]) {
            case .accessibilityHighContrastDarkAqua, .accessibilityHighContrastAqua:
                increasedContrast
            case .darkAqua:
                dark
            default:
                light
            }
        }
    }

    static func sidebarHighlightOpacity(for contrast: ColorSchemeContrast) -> Double {
        contrast == .increased ? 0.20 : 0.10
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
            return DahliaDesign.chipHoverColor
        }
        if let tint {
            return tint.opacity(DahliaDesign.chipTintOpacity)
        }
        return DahliaDesign.contentHighlightColor
    }
}

extension View {
    func dahliaSidebarHoverHighlight(
        isHovered: Bool,
        isSelected: Bool = false,
        verticalOutset: CGFloat = 0.5
    ) -> some View {
        modifier(DahliaSidebarHoverHighlightModifier(
            isHovered: isHovered,
            isSelected: isSelected,
            verticalOutset: verticalOutset
        ))
    }

    func dahliaChipSurface(isHovered: Bool = false, tint: Color? = nil) -> some View {
        modifier(DahliaChipSurface(isHovered: isHovered, tint: tint))
    }
}

private struct DahliaSidebarHoverHighlightModifier: ViewModifier {
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    let isHovered: Bool
    let isSelected: Bool
    let verticalOutset: CGFloat

    func body(content: Content) -> some View {
        let opacity = DahliaDesign.sidebarHighlightOpacity(for: colorSchemeContrast)
        let color = isSelected || isHovered ? Color.primary.opacity(opacity) : Color.clear

        content
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(color)
                    .padding(.vertical, -verticalOutset)
                    .padding(.horizontal, -6)
            }
            .background(NativeListSelectionHighlightSuppressor())
    }
}

private struct NativeListSelectionHighlightSuppressor: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSView {
        SuppressorView()
    }

    func updateNSView(_: NSView, context _: Context) {}

    private final class SuppressorView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()

            var ancestor = superview
            while let view = ancestor {
                if let tableView = view as? NSTableView {
                    tableView.selectionHighlightStyle = .none
                    return
                }
                ancestor = view.superview
            }
        }
    }
}
