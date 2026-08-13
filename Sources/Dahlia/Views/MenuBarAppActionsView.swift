import SwiftUI

struct MenuBarAppActionsView: View {
    let mainWindowNavigation: MainWindowNavigation

    @Environment(\.openWindow) private var openWindow
    @AppStorage(AppSettings.customerIntelligenceBetaEnabledUserDefaultsKey)
    private var isCustomerIntelligenceBetaEnabled = AppSettings.defaultCustomerIntelligenceBetaEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(L10n.menuBarOpenDahlia, systemImage: "macwindow", action: openDahlia)
            Button(L10n.manageProjects, systemImage: "folder", action: openProjectManager)
            if isCustomerIntelligenceBetaEnabled {
                Button(L10n.customerIntelligence, systemImage: "building.2", action: openOrganizationWorkspace)
            }
            Button(L10n.settingsMenuItem, systemImage: "gearshape", action: showSettings)
                .keyboardShortcut(",", modifiers: .command)
            Button(L10n.menuBarQuitDahlia, systemImage: "power", action: quit)
                .keyboardShortcut("q", modifiers: .command)
        }
        .buttonStyle(.borderless)
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            MainWindowOpener.shared.register(openWindow: openWindow)
        }
    }

    private func openDahlia() {
        MainWindowOpener.shared.openMainWindow()
    }

    private func openProjectManager() {
        mainWindowNavigation.openProjects()
    }

    private func openOrganizationWorkspace() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: WindowID.organizationWorkspace)
    }

    private func showSettings() {
        mainWindowNavigation.openSettings()
    }

    private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
