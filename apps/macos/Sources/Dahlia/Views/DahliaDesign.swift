import AppKit
import SwiftUI

enum DahliaDesign {
    enum Button {
        enum InteractionState {
            case normal
            case hovered
            case pressed
        }

        /// A rounded rectangle, not a pill: at a button's height a larger radius closes into a capsule.
        static let cornerRadius: CGFloat = 6
    }

    enum Highlight {
        static let compactCornerRadius: CGFloat = 8
        static let regularCornerRadius: CGFloat = 12
    }

    enum HoverHelp {
        static let cornerRadius: CGFloat = 12
    }

    enum HoverCard {
        static let cornerRadius: CGFloat = 12
    }

    enum Card {
        static let compactCornerRadius: CGFloat = 8
        static let regularCornerRadius: CGFloat = 12
    }

    enum Field {
        static let cornerRadius: CGFloat = 8
    }

    enum Feedback {
        static let cornerRadius: CGFloat = 6
    }

    enum Media {
        static let cornerRadius: CGFloat = 8
    }

    static let sidebarHighlightColor = Color.primary.opacity(0.10)
    static let contentHighlightColor = Color.primary.opacity(0.05)
    static let chipHoverColor = Color.primary.opacity(0.10)
    /// The app's accent: the fill of primary buttons and switches, and the text on primary buttons. Orca's monochrome for now (near black in light
    /// mode, near white in dark); a choice of accent replaces these two values.
    enum Accent {
        static let fill = NSColor(name: nil) { appearance in
            isDark(appearance)
                ? NSColor(srgbRed: 236 / 255, green: 236 / 255, blue: 236 / 255, alpha: 1)
                : NSColor(srgbRed: 24 / 255, green: 24 / 255, blue: 27 / 255, alpha: 1)
        }

        static let onFill = NSColor(name: nil) { appearance in
            isDark(appearance) ? NSColor(srgbRed: 24 / 255, green: 24 / 255, blue: 27 / 255, alpha: 1) : .white
        }
    }

    /// Hover and press move the accent toward the window's background, so any accent keeps its feedback.
    static func primaryButtonBackgroundNSColor(for state: Button.InteractionState) -> NSColor {
        NSColor(name: nil) { appearance in
            var fill = Accent.fill
            appearance.performAsCurrentDrawingAppearance { fill = Accent.fill.usingColorSpace(.sRGB) ?? Accent.fill }
            let fraction: CGFloat = switch state {
            case .normal: 0
            case .hovered: 0.12
            case .pressed: 0.22
            }
            return fill.blended(withFraction: fraction, of: isDark(appearance) ? .black : .white) ?? fill
        }
    }

    private static func isDark(_ appearance: NSAppearance) -> Bool {
        [.darkAqua, .accessibilityHighContrastDarkAqua].contains(
            appearance.bestMatch(from: [.accessibilityHighContrastDarkAqua, .accessibilityHighContrastAqua, .darkAqua, .aqua])
        )
    }

    static func primaryButtonBackgroundColor(for state: Button.InteractionState) -> Color {
        Color(nsColor: primaryButtonBackgroundNSColor(for: state))
    }

    static let primaryButtonForegroundColor = Color(nsColor: Accent.onFill)
    /// Orca's secondary button: the content background (white in light mode), set off by its border. Hover and press
    /// move it toward the text color.
    static func secondaryButtonBackgroundColor(for state: Button.InteractionState) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            var base = NSColor.controlBackgroundColor
            appearance.performAsCurrentDrawingAppearance { base = NSColor.controlBackgroundColor.usingColorSpace(.sRGB) ?? base }
            let fraction: CGFloat = switch state {
            case .normal: 0
            case .hovered: 0.06
            case .pressed: 0.10
            }
            return base.blended(withFraction: fraction, of: isDark(appearance) ? .white : .black) ?? base
        })
    }

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
    static let projectSidebarRowHighlightVerticalOutset: CGFloat = 4
    static let sidebarHoverCardWidth: CGFloat = 280

    static func meetingSidebarRowHighlightVerticalOutset(for rowStyle: MeetingSidebarRowStyle) -> CGFloat {
        rowStyle == .compact ? 4 : 3
    }

    static let windowHeaderHeight: CGFloat = 32
    static let windowHeaderHorizontalPadding: CGFloat = 12
    static let windowControlsLeadingInset: CGFloat = 68
    static let windowHeaderControlSize: CGFloat = 28
    static let windowHeaderGroupSpacing: CGFloat = 4
    static let windowHeaderHelpHorizontalInset: CGFloat = 8

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
    static let detailTopPadding = windowHeaderHeight + 32
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

    func dahliaSidebarHoverCard(width: CGFloat = DahliaDesign.sidebarHoverCardWidth) -> some View {
        modifier(DahliaSidebarHoverCardModifier(width: width))
    }

    func dahliaCardSurface() -> some View {
        background(
            Color(nsColor: .controlBackgroundColor),
            in: .rect(cornerRadius: DahliaDesign.Card.regularCornerRadius)
        )
        .overlay {
            RoundedRectangle(cornerRadius: DahliaDesign.Card.regularCornerRadius)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        }
    }
}

private struct DahliaSidebarHoverCardModifier: ViewModifier {
    let width: CGFloat

    func body(content: Content) -> some View {
        content
            .font(.dahliaBody)
            .foregroundStyle(DahliaDesign.primaryTextColor)
            .padding(12)
            .frame(width: width, alignment: .leading)
            .background(Color(nsColor: .windowBackgroundColor), in: .rect(cornerRadius: DahliaDesign.HoverCard.cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: DahliaDesign.HoverCard.cornerRadius)
                    .strokeBorder(.primary.opacity(0.2), lineWidth: 1)
            }
            .containerShape(.rect(cornerRadius: DahliaDesign.HoverCard.cornerRadius))
            .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
            .fixedSize(horizontal: false, vertical: true)
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
                RoundedRectangle(cornerRadius: DahliaDesign.Highlight.compactCornerRadius)
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
