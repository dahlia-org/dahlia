import SwiftUI

struct AppearanceSettingsView: View {
    @AppStorage(AppSettings.meetingSidebarRowStyleUserDefaultsKey)
    private var meetingSidebarRowStyle = MeetingSidebarRowStyle.standard.rawValue

    var body: some View {
        Form {
            Section(L10n.meetingList) {
                Picker(L10n.displayStyle, selection: $meetingSidebarRowStyle) {
                    ForEach(MeetingSidebarRowStyle.allCases) { style in
                        Text(style.label).tag(style.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            meetingSidebarRowStyle = MeetingSidebarRowStyle.resolved(rawValue: meetingSidebarRowStyle).rawValue
        }
    }
}
