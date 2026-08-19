import SwiftUI

private struct CodexChatHoverHelpModifier: ViewModifier {
    let label: String
    let shortcut: String?

    @State private var helpController = DahliaWindowHeaderHelpController()
    @State private var helpID = UUID()
    @State private var helpSize: CGSize = .zero
    @State private var buttonFrame: CGRect = .zero

    func body(content: Content) -> some View {
        content
            .overlay {
                if helpController.visibleHelpID == helpID {
                    DahliaWindowHeaderHelp(label: label, shortcut: shortcut)
                        .onGeometryChange(for: CGSize.self) { geometry in
                            geometry.size
                        } action: { size in
                            helpSize = size
                        }
                        .offset(x: helpHorizontalOffset, y: helpVerticalOffset)
                        .opacity(helpSize == .zero ? 0 : 1)
                }
            }
            .onGeometryChange(for: CGRect.self) { geometry in
                geometry.frame(in: .global)
            } action: { frame in
                buttonFrame = frame
            }
            .onGeometryChange(for: CGRect.self) { geometry in
                geometry.bounds(of: .named(DahliaWindowHeaderHelpLayout.windowCoordinateSpaceName))
                    ?? geometry.frame(in: .local)
            } action: { bounds in
                helpController.updateWindowBounds(bounds)
            }
            .onHover(perform: updateHover)
            .onDisappear { helpController.hoverEnded(for: helpID) }
            .zIndex(helpController.visibleHelpID == helpID ? 1 : 0)
            .accessibilityHint(Text(verbatim: accessibilityHint))
    }

    private func updateHover(_ isHovering: Bool) {
        if isHovering {
            helpController.hoverBegan(for: helpID)
        } else {
            helpController.hoverEnded(for: helpID)
        }
    }

    private var helpHorizontalOffset: CGFloat {
        DahliaWindowHeaderHelpLayout.horizontalOffset(
            buttonMidX: buttonFrame.width / 2,
            helpWidth: helpSize.width,
            windowBounds: helpController.windowBounds
        )
    }

    private var helpVerticalOffset: CGFloat {
        DahliaWindowHeaderHelpLayout.verticalOffset(
            buttonMinY: buttonFrame.minY,
            helpHeight: helpSize.height,
            buttonHeight: buttonFrame.height
        )
    }

    private var accessibilityHint: String {
        guard let shortcut else { return label }
        return "\(label), \(shortcut)"
    }
}

extension View {
    func codexChatHoverHelp(label: String, shortcut: String? = nil) -> some View {
        modifier(CodexChatHoverHelpModifier(label: label, shortcut: shortcut))
    }
}
