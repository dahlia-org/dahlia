import SwiftUI

struct MenuBarAppActionsView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(L10n.menuBarOpenDahlia, systemImage: "macwindow", action: openDahlia)
            Button(L10n.manageProjects, systemImage: "folder", action: openProjectManager)
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
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: WindowID.projectManager)
    }

    private func showSettings() {
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
    }

    private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
