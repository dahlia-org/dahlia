import SwiftUI

struct OrganizationWorkspaceCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @AppStorage(AppSettings.customerIntelligenceBetaEnabledUserDefaultsKey)
    private var isCustomerIntelligenceBetaEnabled = AppSettings.defaultCustomerIntelligenceBetaEnabled

    var body: some Commands {
        if isCustomerIntelligenceBetaEnabled {
            CommandMenu(L10n.customerIntelligence) {
                Button(L10n.openOrganizationWorkspace) {
                    openWindow(id: WindowID.organizationWorkspace)
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            }
        }
    }
}
