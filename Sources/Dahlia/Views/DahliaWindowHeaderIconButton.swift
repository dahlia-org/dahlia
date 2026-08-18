import SwiftUI

struct DahliaWindowHeaderIconButton: View {
    let label: String
    let systemImage: String
    let helpShortcut: String?
    let showsHoverHighlight: Bool
    let presentsHelpInContainerOverlay: Bool
    let action: () -> Void

    @Environment(DahliaWindowHeaderHelpController.self) private var helpController
    @State private var helpID = UUID()
    @State private var helpSize: CGSize = .zero
    @State private var buttonMidX: CGFloat = 0
    @State private var buttonFrame: CGRect = .zero
    @State private var isHovering = false

    init(
        label: String,
        systemImage: String,
        helpShortcut: String? = nil,
        showsHoverHighlight: Bool = true,
        presentsHelpInContainerOverlay: Bool = false,
        action: @escaping () -> Void
    ) {
        self.label = label
        self.systemImage = systemImage
        self.helpShortcut = helpShortcut
        self.showsHoverHighlight = showsHoverHighlight
        self.presentsHelpInContainerOverlay = presentsHelpInContainerOverlay
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
            if !presentsHelpInContainerOverlay,
               helpController.visibleHelpID == helpID {
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
        .onGeometryChange(for: CGRect.self) { geometry in
            geometry.frame(in: .global)
        } action: { frame in
            buttonFrame = frame
        }
        .onHover(perform: updateHoverState)
        .onDisappear { helpController.hoverEnded(for: helpID) }
        .zIndex(helpController.visibleHelpID == helpID ? 1 : 0)
        .accessibilityLabel(label)
    }

    private func updateHoverState(_ isHovering: Bool) {
        self.isHovering = isHovering
        if isHovering {
            helpController.hoverBegan(
                for: helpID,
                label: label,
                shortcut: helpShortcut,
                buttonFrame: buttonFrame
            )
        } else {
            helpController.hoverEnded(for: helpID)
        }
    }

    private var helpHorizontalOffset: CGFloat {
        DahliaWindowHeaderHelpLayout.horizontalOffset(
            buttonMidX: buttonMidX,
            helpWidth: helpSize.width,
            windowBounds: helpController.windowBounds
        )
    }

    private var helpVerticalOffset: CGFloat {
        DahliaWindowHeaderHelpLayout.verticalOffset(
            buttonMinY: buttonFrame.minY,
            helpHeight: helpSize.height
        )
    }
}
