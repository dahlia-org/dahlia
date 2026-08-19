import SwiftUI

private struct DahliaAppearanceModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.body)
            .foregroundStyle(DahliaDesign.primaryTextColor)
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
    func dahliaAppearance() -> some View {
        modifier(DahliaAppearanceModifier())
    }

    func dahliaFixedSymbol() -> some View {
        font(.body)
    }
}
