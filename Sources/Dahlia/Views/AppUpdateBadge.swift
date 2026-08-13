import SwiftUI

struct AppUpdateBadge: View {
    var updateController: AppUpdateController
    @State private var isShowingUpdateConfirmation = false

    var body: some View {
        Button(
            L10n.update,
            systemImage: "arrow.down.circle.fill",
            action: showUpdateConfirmation
        )
        .labelStyle(.titleAndIcon)
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.mini)
        .help(helpText)
        .alert(L10n.update, isPresented: $isShowingUpdateConfirmation) {
            Button(L10n.later, role: .cancel) {}
            Button(L10n.update, action: updateController.showUpdateDialog)
        } message: {
            Text(helpText)
        }
    }

    private func showUpdateConfirmation() {
        isShowingUpdateConfirmation = true
    }

    private var helpText: String {
        guard let version = updateController.availableVersion else {
            return L10n.updateAvailable
        }
        return L10n.updateAvailableVersion(version)
    }
}
