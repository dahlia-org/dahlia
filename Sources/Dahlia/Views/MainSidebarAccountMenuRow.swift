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
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                } else if let selectionState {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .opacity(selectionState ? 1 : 0)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .contentShape(.rect(cornerRadius: 7))
            .background(
                (isHovered || isKeyboardHighlighted) && isEnabled ? Color.primary.opacity(0.07) : .clear,
                in: .rect(cornerRadius: 7)
            )
            .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
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
