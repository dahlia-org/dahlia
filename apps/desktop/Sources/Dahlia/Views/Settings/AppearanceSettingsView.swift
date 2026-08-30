import SwiftUI

struct AppearanceSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @AppStorage(AppSettings.meetingSidebarRowStyleUserDefaultsKey)
    private var meetingSidebarRowStyle = MeetingSidebarRowStyle.standard.rawValue

    var body: some View {
        Form {
            Section(L10n.display) {
                DahliaMenuPicker(
                    title: L10n.appLanguage,
                    description: L10n.appLanguageDescription,
                    selection: $settings.appLanguage,
                    options: AppLanguage.allCases,
                    label: \.displayName
                )
            }

            Section {
                DahliaSegmentedPicker(
                    title: L10n.sidebarDisplayStyle,
                    selection: $meetingSidebarRowStyle,
                    options: MeetingSidebarRowStyle.allCases.map(\.rawValue)
                ) { MeetingSidebarRowStyle.resolved(rawValue: $0).label }
            } header: {
                Text(L10n.meetingSidebar)
            } footer: {
                Text(L10n.sidebarDisplayStyleDescription)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            meetingSidebarRowStyle = MeetingSidebarRowStyle.resolved(rawValue: meetingSidebarRowStyle).rawValue
        }
    }
}
