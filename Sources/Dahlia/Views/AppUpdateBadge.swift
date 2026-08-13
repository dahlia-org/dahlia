import SwiftUI

struct AppUpdateBadge: View {
    var updateController: AppUpdateController

    var body: some View {
        Button(
            L10n.updateAvailable,
            systemImage: "arrow.down.circle.fill",
            action: updateController.showUpdateDialog
        )
        .labelStyle(.titleAndIcon)
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .help(helpText)
    }

    private var helpText: String {
        guard let version = updateController.availableVersion else {
            return L10n.updateAvailable
        }
        return L10n.updateAvailableVersion(version)
    }
}
