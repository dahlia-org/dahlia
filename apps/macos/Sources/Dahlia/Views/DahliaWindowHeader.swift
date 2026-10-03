import SwiftUI

struct DahliaWindowHeader<Content: View>: View {
    let reservesWindowControls: Bool
    let allowsWindowDragging: Bool
    let backgroundColor: Color
    @ViewBuilder let content: Content

    @State private var helpController = DahliaWindowHeaderHelpController()

    init(
        reservesWindowControls: Bool = false,
        allowsWindowDragging: Bool = true,
        backgroundColor: Color = Color(nsColor: .windowBackgroundColor),
        @ViewBuilder content: () -> Content
    ) {
        self.reservesWindowControls = reservesWindowControls
        self.allowsWindowDragging = allowsWindowDragging
        self.backgroundColor = backgroundColor
        self.content = content()
    }

    var body: some View {
        HStack(spacing: DahliaDesign.windowHeaderGroupSpacing) {
            if reservesWindowControls {
                Color.clear
                    .frame(width: DahliaDesign.windowControlsLeadingInset)
                    .accessibilityHidden(true)
            }
            content
        }
        .padding(.horizontal, DahliaDesign.windowHeaderHorizontalPadding)
        .frame(maxWidth: .infinity)
        .frame(height: DahliaDesign.windowHeaderHeight)
        .background {
            if allowsWindowDragging {
                backgroundColor
                    .contentShape(.rect)
                    .gesture(WindowDragGesture())
                    .allowsWindowActivationEvents(true)
            } else {
                backgroundColor
                    .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .coordinateSpace(name: DahliaWindowHeaderHelpLayout.coordinateSpaceName)
        .onGeometryChange(for: CGRect.self) { geometry in
            geometry.bounds(of: .named(DahliaWindowHeaderHelpLayout.windowCoordinateSpaceName))
                ?? geometry.frame(in: .local)
        } action: { bounds in
            helpController.updateWindowBounds(bounds)
        }
        .environment(helpController)
    }
}
