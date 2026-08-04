import SwiftUI

struct CodexChatApprovalButton: View {
    enum Prominence {
        case primary
        case secondary
    }

    let title: String
    let prominence: Prominence
    let isEnabled: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .frame(minHeight: 36)
            .foregroundStyle(prominence == .primary ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .background(backgroundStyle, in: Capsule())
            .overlay {
                if prominence == .secondary {
                    Capsule()
                        .stroke(.secondary.opacity(0.25), lineWidth: 1)
                }
            }
            .disabled(!isEnabled)
            .opacity(isEnabled ? 1 : 0.6)
            .onHover { isHovering = $0 }
            .accessibilityInputLabels([title])
    }

    private var backgroundStyle: AnyShapeStyle {
        switch prominence {
        case .primary:
            if isHovering {
                AnyShapeStyle(.primary.opacity(0.72))
            } else {
                AnyShapeStyle(.primary.opacity(0.85))
            }
        case .secondary:
            if isHovering {
                AnyShapeStyle(.quaternary)
            } else {
                AnyShapeStyle(.background)
            }
        }
    }
}
