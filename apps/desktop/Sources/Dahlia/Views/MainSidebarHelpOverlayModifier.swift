import SwiftUI

private struct MainSidebarHelpOverlayModifier: ViewModifier {
    let isVisible: Bool

    @State private var helpController = DahliaWindowHeaderHelpController()
    @State private var containerOrigin: CGPoint = .zero

    func body(content: Content) -> some View {
        content
            .environment(helpController)
            .onGeometryChange(for: CGPoint.self) { geometry in
                geometry.frame(in: .global).origin
            } action: { origin in
                containerOrigin = origin
            }
            .onGeometryChange(for: CGRect.self) { geometry in
                geometry.bounds(of: .named(DahliaWindowHeaderHelpLayout.windowCoordinateSpaceName))
                    ?? geometry.frame(in: .local)
            } action: { bounds in
                helpController.updateWindowBounds(bounds)
            }
            .overlay {
                if isVisible {
                    DahliaWindowHeaderHelpOverlay(
                        helpController: helpController,
                        containerOrigin: containerOrigin
                    )
                }
            }
            .onChange(of: isVisible) { _, isVisible in
                if !isVisible {
                    helpController.dismissAll()
                }
            }
    }
}

extension View {
    func mainSidebarHelpOverlay(isVisible: Bool) -> some View {
        modifier(MainSidebarHelpOverlayModifier(isVisible: isVisible))
    }
}
