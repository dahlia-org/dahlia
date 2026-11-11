import AppKit
import SwiftUI

enum DahliaTypography {
    static let defaultBaseSize: CGFloat = 14
    static let baseSizeUserDefaultsKey = "interfaceTextSize"
    static let baseSizeOptions = [12, 13, 14, 15, 16, 17, 18]

    /// The text size chosen in Appearance. Read from defaults, as `L10n` reads the language, so every style follows it.
    static var baseSize: CGFloat { baseSize(in: .standard) }

    static func baseSize(in defaults: UserDefaults) -> CGFloat {
        let stored = defaults.integer(forKey: baseSizeUserDefaultsKey)
        return baseSizeOptions.contains(stored) ? CGFloat(stored) : defaultBaseSize
    }

    static func size(offset: CGFloat = 0, relativeTo baseSize: CGFloat = Self.baseSize) -> CGFloat {
        baseSize + offset
    }
}

extension Font {
    static var dahliaBody: Font { .system(size: DahliaTypography.size()) }
    static var dahliaHeadline: Font { .dahliaBody.bold() }
    static var dahliaSecondary: Font { .system(size: DahliaTypography.size(offset: -2)) }
    static var dahliaSectionHeader: Font { .dahliaSecondary.weight(.medium) }
    static var dahliaTitle3: Font { .system(size: DahliaTypography.size(offset: 1)) }
    static var dahliaTitle2: Font { .system(size: DahliaTypography.size(offset: 3)) }
    static var dahliaTitle: Font { .system(size: DahliaTypography.size(offset: 8)) }
    static var dahliaLargeTitle: Font { .system(size: DahliaTypography.size(offset: 12)) }
}

extension NSFont {
    static var dahliaBody: NSFont { .systemFont(ofSize: DahliaTypography.size()) }
    static var dahliaHeadline: NSFont { .boldSystemFont(ofSize: DahliaTypography.size()) }
    static var dahliaSecondary: NSFont { .systemFont(ofSize: DahliaTypography.size(offset: -2)) }
    static var dahliaTitle3: NSFont { .systemFont(ofSize: DahliaTypography.size(offset: 1)) }
}

private struct DahliaAppearanceModifier: ViewModifier {
    /// Re-applies the inherited body font when the text size changes.
    @AppStorage(DahliaTypography.baseSizeUserDefaultsKey) private var baseSize = Int(DahliaTypography.defaultBaseSize)

    func body(content: Content) -> some View {
        content
            .font(.dahliaBody)
            .foregroundStyle(DahliaDesign.primaryTextColor)
            .labelStyle(DahliaFixedSymbolLabelStyle())
            .buttonBorderShape(.roundedRectangle(radius: DahliaDesign.Button.cornerRadius))
    }
}

struct DahliaFixedSymbolLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        Label {
            configuration.title
        } icon: {
            configuration.icon
                .dahliaFixedSymbol()
        }
        .labelStyle(.automatic)
    }
}

struct DahliaFixedSymbolTitleAndIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        Label {
            configuration.title
        } icon: {
            configuration.icon
                .dahliaFixedSymbol()
        }
        .labelStyle(.titleAndIcon)
    }
}

extension View {
    func dahliaAppearance() -> some View {
        modifier(DahliaAppearanceModifier())
    }

    func dahliaFixedSymbol() -> some View {
        font(.dahliaBody)
    }
}
