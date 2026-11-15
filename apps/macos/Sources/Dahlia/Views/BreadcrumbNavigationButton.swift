import SwiftUI

struct BreadcrumbNavigationButton: View {
    let title: String
    let systemImage: String
    var hasExportFolder = false
    let action: () -> Void

    @Environment(BreadcrumbHoverSession.self) private var hoverSession

    var body: some View {
        MainSidebarAccountMenuRow(title: title, image: Image(systemName: systemImage), hasExportFolder: hasExportFolder) {
            hoverSession.dismissAll()
            action()
        }
    }
}
