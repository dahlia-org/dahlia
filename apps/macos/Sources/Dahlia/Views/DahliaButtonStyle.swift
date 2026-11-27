import SwiftUI

enum DahliaButtonVariant {
    case primary
    case secondary
    case destructive
}

struct DahliaButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    let variant: DahliaButtonVariant
    let cornerRadius: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        // A destructive role on the default style reads as destructive, as it does on native buttons.
        let variant = variant == .secondary && configuration.role == .destructive ? .destructive : variant
        configuration.label
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundStyle(foregroundColor(variant))
            .background(
                backgroundColor(variant, isPressed: configuration.isPressed),
                in: .rect(cornerRadius: cornerRadius)
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(borderColor(variant), lineWidth: 1)
            }
            .contentShape(.rect(cornerRadius: cornerRadius))
            .opacity(isEnabled ? 1 : 0.45)
            // Set by hand, as the split views' dividers do: inside a `List` (the sidebar's), `pointerStyle` is overridden.
            .onContinuousHover { phase in
                isHovered = phase != .ended
                (isHovered && isEnabled ? NSCursor.pointingHand : NSCursor.arrow).set()
            }
    }

    private func foregroundColor(_ variant: DahliaButtonVariant) -> Color {
        switch variant {
        case .primary:
            DahliaDesign.primaryButtonForegroundColor
        case .secondary:
            DahliaDesign.primaryTextColor
        case .destructive:
            .red
        }
    }

    private func backgroundColor(_ variant: DahliaButtonVariant, isPressed: Bool) -> Color {
        switch variant {
        case .primary:
            DahliaDesign.primaryButtonBackgroundColor(for: interactionState(isPressed: isPressed))
        case .secondary:
            DahliaDesign.secondaryButtonBackgroundColor(for: interactionState(isPressed: isPressed))
        case .destructive:
            Color.primary.opacity(isPressed ? 0.14 : isHovered ? 0.10 : 0.06)
        }
    }

    private func interactionState(isPressed: Bool) -> DahliaDesign.Button.InteractionState {
        if isPressed { return .pressed }
        if isHovered { return .hovered }
        return .normal
    }

    private func borderColor(_ variant: DahliaButtonVariant) -> Color {
        switch variant {
        case .primary:
            .clear
        case .secondary:
            Color.primary.opacity(0.15)
        case .destructive:
            Color.red.opacity(0.18)
        }
    }
}

extension ButtonStyle where Self == DahliaButtonStyle {
    static func dahlia(
        _ variant: DahliaButtonVariant = .secondary,
        cornerRadius: CGFloat = DahliaDesign.Button.cornerRadius
    ) -> DahliaButtonStyle {
        DahliaButtonStyle(variant: variant, cornerRadius: cornerRadius)
    }
}
