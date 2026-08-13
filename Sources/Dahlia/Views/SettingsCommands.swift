import SwiftUI

struct SettingsCommands: Commands {
    let mainWindowNavigation: MainWindowNavigation

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button(L10n.settingsMenuItem) {
                mainWindowNavigation.openSettings()
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }
}
