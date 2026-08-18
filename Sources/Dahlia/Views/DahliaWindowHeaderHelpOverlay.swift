import SwiftUI

struct DahliaWindowHeaderHelpOverlay: View {
    let helpController: DahliaWindowHeaderHelpController
    let containerOrigin: CGPoint

    @State private var helpSize: CGSize = .zero

    var body: some View {
        ZStack(alignment: .topLeading) {
            if helpController.visibleHelpID != nil {
                DahliaWindowHeaderHelp(
                    label: helpController.helpLabel,
                    shortcut: helpController.helpShortcut
                )
                .onGeometryChange(for: CGSize.self) { geometry in
                    geometry.size
                } action: { size in
                    helpSize = size
                }
                .offset(x: helpOrigin.x, y: helpOrigin.y)
                .opacity(helpSize == .zero ? 0 : 1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private var helpOrigin: CGPoint {
        DahliaWindowHeaderHelpLayout.origin(
            buttonFrame: helpController.helpButtonFrame,
            helpSize: helpSize,
            containerOrigin: containerOrigin,
            windowBounds: helpController.windowBounds
        )
    }
}
