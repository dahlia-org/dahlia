import SwiftUI

extension View {
    func mainSidebarPane(
        width: CGFloat,
        minimumWidth: CGFloat = MainSidebarLayout.minimumWidth,
        maximumWidth: CGFloat = MainSidebarLayout.maximumWidth,
        isVisible: Bool = true,
        widthSourceID: Int = 0,
        onWidthChange: @escaping (CGFloat) -> Void
    ) -> some View {
        frame(
            minWidth: isVisible ? minimumWidth : 0,
            idealWidth: isVisible ? width : 0,
            maxWidth: isVisible ? maximumWidth : 0,
            alignment: .trailing
        )
        .clipped()
        .background {
            SidebarMaterialBackground()
                .overlay {
                    Color(nsColor: .windowBackgroundColor)
                        .opacity(MainSidebarLayout.tintOpacity)
                }
                .ignoresSafeArea()
        }
        .background {
            DeferredSplitViewWidthSyncView(
                width: width,
                onWidthChange: onWidthChange,
                widthSourceID: widthSourceID,
                isVisible: isVisible
            )
        }
    }
}
