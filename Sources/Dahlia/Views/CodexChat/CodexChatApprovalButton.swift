import SwiftUI

struct CodexChatApprovalButton: View {
    enum Prominence {
        case primary
        case secondary
    }

    let title: String
    var helpText: String?
    let prominence: Prominence
    let isEnabled: Bool
    let action: () -> Void

    @State private var isHovering = false
    @State private var isHelpPresented = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                if let helpText {
                    Image(systemName: "info.circle")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                        .onHover(perform: showHelpOnHover)
                        .popover(isPresented: $isHelpPresented, arrowEdge: .bottom) {
                            Text(helpText)
                                .font(.callout)
                                .padding(12)
                        }
                        .accessibilityLabel(helpText)
                }
            }
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
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
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
                AnyShapeStyle(DahliaDesign.hoverHighlightColor)
            } else {
                AnyShapeStyle(.background)
            }
        }
    }

    private func showHelpOnHover(_ isHovering: Bool) {
        isHelpPresented = isHovering
    }
}
