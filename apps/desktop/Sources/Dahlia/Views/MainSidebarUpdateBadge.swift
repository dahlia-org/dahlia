import SwiftUI

struct MainSidebarUpdateBadge: View {
    var updateController: AppUpdateController

    @State private var isHovered = false

    var body: some View {
        Button(L10n.update, action: updateController.showUpdateDialog)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .foregroundStyle(.white)
            .background(backgroundColor, in: Capsule())
            .contentShape(Capsule())
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .help(helpText)
    }

    private var backgroundColor: Color {
        isHovered ? Color.accentColor.opacity(0.85) : Color.accentColor
    }

    private var helpText: String {
        guard let version = updateController.availableVersion else {
            return L10n.updateAvailable
        }
        return L10n.updateAvailableVersion(version)
    }
}
