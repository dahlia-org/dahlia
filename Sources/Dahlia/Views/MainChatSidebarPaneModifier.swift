import SwiftUI

extension View {
    func mainChatSidebarPane(
        width: CGFloat,
        isVisible: Bool = true,
        onWidthChange: @escaping (CGFloat) -> Void
    ) -> some View {
        frame(
            minWidth: isVisible ? MainChatSidebarLayout.minimumWidth : 0,
            idealWidth: isVisible ? width : 0,
            maxWidth: isVisible ? MainChatSidebarLayout.maximumWidth : 0
        )
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(isVisible)
        .disabled(!isVisible)
        .accessibilityHidden(!isVisible)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { actualWidth in
            if isVisible {
                onWidthChange(actualWidth)
            }
        }
        .background {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()
        }
        .background {
            if isVisible {
                SplitViewWidthSyncView(
                    width: width,
                    onWidthChange: onWidthChange,
                    pane: .last
                )
            }
        }
    }
}
