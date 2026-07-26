import SwiftUI

struct OrganizationWorkspaceCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu(L10n.organizations) {
            Button(L10n.openOrganizationWorkspace) {
                openWindow(id: WindowID.organizationWorkspace)
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
        }
    }
}
