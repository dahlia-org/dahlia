import SwiftUI

/// Mac-wide appearance, language, and notification preferences.
struct GeneralSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @AppStorage(AppSettings.meetingSidebarRowStyleUserDefaultsKey)
    private var meetingSidebarRowStyle = MeetingSidebarRowStyle.standard.rawValue

    var body: some View {
        Form {
            Section(L10n.display) {
                DahliaMenuPicker(
                    title: L10n.appLanguage,
                    selection: $settings.appLanguage,
                    options: AppLanguage.allCases,
                    label: \.displayName
                )
                DahliaSegmentedPicker(
                    title: L10n.sidebarDisplayStyle,
                    selection: $meetingSidebarRowStyle,
                    options: MeetingSidebarRowStyle.allCases.map(\.rawValue)
                ) { MeetingSidebarRowStyle.resolved(rawValue: $0).label }
            }

            Section {
                AppLanguageSelectionRow()
            } header: {
                Text(L10n.appLanguages)
            } footer: {
                Text(L10n.appLanguagesDescription)
            }

            Section {
                Toggle(isOn: $settings.meetingDetectionEnabled) {
                    Text(L10n.meetingNotifications)
                    Text(L10n.meetingNotificationsDescription)
                }
                .toggleStyle(.switch)

                Picker(selection: $settings.meetingNotificationPresentation) {
                    ForEach(MeetingNotificationPresentation.allCases) { presentation in
                        Text(presentation.displayName)
                            .tag(presentation)
                    }
                } label: {
                    Text(L10n.notificationPresentation)
                    Text(L10n.notificationPresentationDescription)
                }
                .disabled(!settings.meetingDetectionEnabled)

                LabeledContent {
                    VStack(alignment: .leading) {
                        Toggle(
                            L10n.microphoneActivityNotification,
                            isOn: $settings.microphoneMeetingNotificationsEnabled
                        )
                        .toggleStyle(.checkbox)

                        Toggle(
                            L10n.calendarEventNotification,
                            isOn: $settings.calendarEventMeetingNotificationsEnabled
                        )
                        .toggleStyle(.checkbox)
                    }
                } label: {
                    Text(L10n.notificationConditions)
                    Text(L10n.notificationConditionsDescription)
                }
                .disabled(!settings.meetingDetectionEnabled)
            } header: {
                Text(L10n.notifications)
            } footer: {
                VStack(alignment: .leading) {
                    Text(L10n.notificationSettingsDescription)
                    if !settings.meetingDetectionEnabled {
                        Text(L10n.enableMeetingNotificationsToChooseConditions)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            meetingSidebarRowStyle = MeetingSidebarRowStyle.resolved(rawValue: meetingSidebarRowStyle).rawValue
        }
    }
}
