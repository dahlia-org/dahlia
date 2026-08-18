import SwiftUI

struct DahliaWindowHeaderIconButton: View {
    let label: String
    let systemImage: String
    let helpShortcut: String?
    let action: () -> Void

    @Environment(DahliaWindowHeaderHelpController.self) private var helpController
    @State private var helpID = UUID()
    @State private var helpWidth: CGFloat = 0
    @State private var buttonMidX: CGFloat = 0
    @State private var isHovering = false

    init(
        label: String,
        systemImage: String,
        helpShortcut: String? = nil,
        action: @escaping () -> Void
    ) {
        self.label = label
        self.systemImage = systemImage
        self.helpShortcut = helpShortcut
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Label(label, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .dahliaFixedSymbol()
                .frame(
                    width: DahliaDesign.windowHeaderControlSize,
                    height: DahliaDesign.windowHeaderControlSize
                )
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background(
            isHovering ? DahliaDesign.hoverHighlightColor : .clear,
            in: .rect(cornerRadius: 8)
        )
        .overlay(alignment: .bottom) {
            if helpController.visibleHelpID == helpID {
                DahliaWindowHeaderHelp(label: label, shortcut: helpShortcut)
                    .onGeometryChange(for: CGFloat.self) { geometry in
                        geometry.size.width
                    } action: { width in
                        helpWidth = width
                    }
                    .offset(x: helpHorizontalOffset, y: 42)
                    .opacity(helpWidth > 0 ? 1 : 0)
            }
        }
        .onGeometryChange(for: CGFloat.self) { geometry in
            geometry.frame(in: .named(DahliaWindowHeaderHelpLayout.coordinateSpaceName)).midX
        } action: { midX in
            buttonMidX = midX
        }
        .onHover(perform: updateHoverState)
        .onDisappear { helpController.hoverEnded(for: helpID) }
        .zIndex(helpController.visibleHelpID == helpID ? 1 : 0)
        .accessibilityLabel(label)
    }

    private func updateHoverState(_ isHovering: Bool) {
        self.isHovering = isHovering
        if isHovering {
            helpController.hoverBegan(for: helpID)
        } else {
            helpController.hoverEnded(for: helpID)
        }
    }

    private var helpHorizontalOffset: CGFloat {
        DahliaWindowHeaderHelpLayout.horizontalOffset(
            buttonMidX: buttonMidX,
            helpWidth: helpWidth,
            containerWidth: helpController.containerWidth
        )
    }
}
