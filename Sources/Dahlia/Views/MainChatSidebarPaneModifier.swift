import SwiftUI

extension View {
    func mainChatSidebarPane(
        width: CGFloat,
        onWidthChange: @escaping (CGFloat) -> Void
    ) -> some View {
        frame(
            minWidth: MainChatSidebarLayout.minimumWidth,
            idealWidth: width,
            maxWidth: MainChatSidebarLayout.maximumWidth
        )
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { actualWidth in
            onWidthChange(actualWidth)
        }
        .background {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()
        }
        .background {
            SplitViewWidthSyncView(
                width: width,
                onWidthChange: onWidthChange,
                pane: .last
            )
        }
    }
}
