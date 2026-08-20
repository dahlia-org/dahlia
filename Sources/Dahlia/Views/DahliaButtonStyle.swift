import SwiftUI

enum DahliaButtonVariant {
    case primary
    case secondary
    case destructive
}

struct DahliaButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    let variant: DahliaButtonVariant

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundStyle(foregroundColor)
            .background(backgroundColor(isPressed: configuration.isPressed), in: .rect(cornerRadius: DahliaDesign.Button.cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: DahliaDesign.Button.cornerRadius)
                    .strokeBorder(borderColor, lineWidth: 1)
            }
            .contentShape(.rect(cornerRadius: DahliaDesign.Button.cornerRadius))
            .opacity(isEnabled ? 1 : 0.45)
    }

    private var foregroundColor: Color {
        switch variant {
        case .primary:
            Color(nsColor: .selectedControlTextColor)
        case .secondary:
            DahliaDesign.primaryTextColor
        case .destructive:
            .red
        }
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        switch variant {
        case .primary:
            Color.accentColor.opacity(isPressed ? 0.72 : 1)
        case .secondary, .destructive:
            Color.primary.opacity(isPressed ? 0.12 : 0.06)
        }
    }

    private var borderColor: Color {
        switch variant {
        case .primary:
            .clear
        case .secondary:
            Color.primary.opacity(0.10)
        case .destructive:
            Color.red.opacity(0.18)
        }
    }
}

extension ButtonStyle where Self == DahliaButtonStyle {
    static func dahlia(_ variant: DahliaButtonVariant = .secondary) -> DahliaButtonStyle {
        DahliaButtonStyle(variant: variant)
    }
}
