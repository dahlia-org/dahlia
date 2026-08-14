import SwiftUI

extension View {
    func mainSidebarPane(
        width: CGFloat,
        onWidthChange: @escaping (CGFloat) -> Void
    ) -> some View {
        frame(
            minWidth: MainSidebarLayout.minimumWidth,
            idealWidth: width,
            maxWidth: MainSidebarLayout.maximumWidth
        )
        .background {
            SidebarMaterialBackground()
                .overlay {
                    Color(nsColor: .windowBackgroundColor)
                        .opacity(MainSidebarLayout.tintOpacity)
                }
                .ignoresSafeArea()
        }
        .background {
            SplitViewWidthSyncView(
                width: width,
                onWidthChange: onWidthChange
            )
        }
    }
}
