import SwiftUI

struct DahliaWindowHeaderIconButton: View {
    let label: String
    let systemImage: String
    let helpShortcut: String?
    let showsHoverHighlight: Bool
    let action: () -> Void

    @Environment(DahliaWindowHeaderHelpController.self) private var helpController
    @State private var helpID = UUID()
    @State private var helpSize: CGSize = .zero
    @State private var buttonMidX: CGFloat = 0
    @State private var buttonMinY: CGFloat = 0
    @State private var isHovering = false

    init(
        label: String,
        systemImage: String,
        helpShortcut: String? = nil,
        showsHoverHighlight: Bool = true,
        action: @escaping () -> Void
    ) {
        self.label = label
        self.systemImage = systemImage
        self.helpShortcut = helpShortcut
        self.showsHoverHighlight = showsHoverHighlight
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
            isHovering && showsHoverHighlight ? DahliaDesign.hoverHighlightColor : .clear,
            in: .rect(cornerRadius: 8)
        )
        .overlay {
            if helpController.visibleHelpID == helpID {
                DahliaWindowHeaderHelp(label: label, shortcut: helpShortcut)
                    .onGeometryChange(for: CGSize.self) { geometry in
                        geometry.size
                    } action: { size in
                        helpSize = size
                    }
                    .offset(x: helpHorizontalOffset, y: helpVerticalOffset)
                    .opacity(helpSize != .zero ? 1 : 0)
            }
        }
        .onGeometryChange(for: CGFloat.self) { geometry in
            geometry.frame(in: .named(DahliaWindowHeaderHelpLayout.coordinateSpaceName)).midX
        } action: { midX in
            buttonMidX = midX
        }
        .onGeometryChange(for: CGFloat.self) { geometry in
            geometry.frame(in: .global).minY
        } action: { minY in
            buttonMinY = minY
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
            helpWidth: helpSize.width,
            containerWidth: helpController.containerWidth
        )
    }

    private var helpVerticalOffset: CGFloat {
        DahliaWindowHeaderHelpLayout.verticalOffset(
            buttonMinY: buttonMinY,
            helpHeight: helpSize.height
        )
    }
}
