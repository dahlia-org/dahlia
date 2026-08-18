import SwiftUI

enum DahliaFontRole: CGFloat, Sendable {
    case displayTitle = 8
    case sectionTitle = 4
    case subsectionTitle = 2
    case body = 0
    case secondary = -2
    case metadata = -4

    func pointSize(baseSize: CGFloat) -> CGFloat {
        baseSize + rawValue
    }
}

enum DahliaTypography {
    static func normalizedBaseSize(_ size: Int) -> Int {
        min(max(size, AppSettings.minimumInterfaceFontSize), AppSettings.maximumInterfaceFontSize)
    }
}

// swiftformat:disable environmentEntry redundantType
private struct DahliaBaseFontSizeKey: EnvironmentKey {
    static let defaultValue = CGFloat(AppSettings.defaultInterfaceFontSize)
}

extension EnvironmentValues {
    var dahliaBaseFontSize: CGFloat {
        get { self[DahliaBaseFontSizeKey.self] }
        set { self[DahliaBaseFontSizeKey.self] = newValue }
    }
}

// swiftformat:enable environmentEntry redundantType

private struct DahliaFontModifier: ViewModifier {
    @Environment(\.dahliaBaseFontSize) private var baseSize

    let role: DahliaFontRole
    let weight: Font.Weight
    let design: Font.Design

    func body(content: Content) -> some View {
        content.font(.system(size: role.pointSize(baseSize: baseSize), weight: weight, design: design))
    }
}

private struct DahliaAppearanceModifier: ViewModifier {
    @AppStorage(AppSettings.interfaceFontSizeUserDefaultsKey)
    private var storedBaseSize = AppSettings.defaultInterfaceFontSize

    func body(content: Content) -> some View {
        let baseSize = CGFloat(DahliaTypography.normalizedBaseSize(storedBaseSize))
        content
            .environment(\.dahliaBaseFontSize, baseSize)
            .font(.system(size: baseSize))
            .labelStyle(DahliaFixedSymbolLabelStyle())
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
    func dahliaFont(
        _ role: DahliaFontRole,
        weight: Font.Weight = .regular,
        design: Font.Design = .default
    ) -> some View {
        modifier(DahliaFontModifier(role: role, weight: weight, design: design))
    }

    func dahliaAppearance() -> some View {
        modifier(DahliaAppearanceModifier())
    }

    func dahliaFixedSymbol() -> some View {
        font(.system(size: CGFloat(AppSettings.defaultInterfaceFontSize)))
    }
}
