import SwiftUI

struct AppUpdateBadge: View {
    var updateController: AppUpdateController
    @State private var isHovered = false

    var body: some View {
        Button(action: updateController.showUpdateDialog) {
            Label(L10n.update, systemImage: "arrow.down.circle.fill")
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(AppUpdateBadgeButtonStyle(isHovered: isHovered))
        .onHover { isHovered = $0 }
        .help(helpText)
    }

    private var helpText: String {
        guard let version = updateController.availableVersion else {
            return L10n.updateAvailable
        }
        return L10n.updateAvailableVersion(version)
    }
}
