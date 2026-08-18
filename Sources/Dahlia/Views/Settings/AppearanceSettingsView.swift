import SwiftUI

struct AppearanceSettingsView: View {
    @AppStorage(AppSettings.interfaceFontSizeUserDefaultsKey)
    private var baseFontSize = AppSettings.defaultInterfaceFontSize
    @AppStorage(AppSettings.meetingSidebarRowStyleUserDefaultsKey)
    private var meetingSidebarRowStyle = MeetingSidebarRowStyle.standard.rawValue

    var body: some View {
        Form {
            Section(L10n.typography) {
                LabeledContent(L10n.fontSize) {
                    Stepper(
                        value: $baseFontSize,
                        in: AppSettings.minimumInterfaceFontSize ... AppSettings.maximumInterfaceFontSize
                    ) {
                        Text(L10n.pointSize(baseFontSize))
                            .monospacedDigit()
                    }
                }
            }

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
            baseFontSize = DahliaTypography.normalizedBaseSize(baseFontSize)
            meetingSidebarRowStyle = MeetingSidebarRowStyle.resolved(rawValue: meetingSidebarRowStyle).rawValue
        }
    }
}
