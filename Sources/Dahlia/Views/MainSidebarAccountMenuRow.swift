import SwiftUI

struct MainSidebarAccountMenuRow: View {
    let title: String
    var image: Image?
    var showsDisclosure = false
    var selectionState: Bool?
    var isEnabled = true
    var isKeyboardHighlighted = false
    var onHoverStart: (() -> Void)?
    var onHoverEnd: (() -> Void)?
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let image {
                    image
                        .resizable()
                        .scaledToFit()
                        .frame(width: 16, height: 16)
                        .frame(width: 18)
                }

                Text(title)
                    .lineLimit(1)

                Spacer(minLength: 12)

                if showsDisclosure {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(DahliaDesign.secondaryTextColor)
                        .accessibilityHidden(true)
                } else if let selectionState {
                    Image(systemName: "checkmark")
                        .dahliaFixedSymbol()
                        .foregroundStyle(.tint)
                        .opacity(selectionState ? 1 : 0)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .contentShape(.rect(corners: .concentric(
                minimum: .fixed(DahliaDesign.Highlight.compactCornerRadius)
            )))
            .background(
                (isHovered || isKeyboardHighlighted) && isEnabled ? DahliaDesign.sidebarHighlightColor : .clear,
                in: .rect(corners: .concentric(
                    minimum: .fixed(DahliaDesign.Highlight.compactCornerRadius)
                ))
            )
            .font(.body.bold())
            .foregroundStyle(DahliaDesign.sidebarPrimaryTextColor)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
        .help(title)
        .accessibilityAddTraits(selectionState == true ? .isSelected : [])
        .onHover { hovered in
            isHovered = hovered
            if hovered {
                onHoverStart?()
            } else {
                onHoverEnd?()
            }
        }
    }
}
