import SwiftUI

/// Mac-wide language, notification, and audio input preferences. How the app looks is in `AppearanceSettingsView`.
struct GeneralSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                AppLanguageSelectionRow()
            } header: {
                Text(L10n.appLanguages)
                    .font(.dahliaSectionHeader)
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
                            .font(.dahliaBody)
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
                    .font(.dahliaSectionHeader)
            } footer: {
                VStack(alignment: .leading) {
                    Text(L10n.notificationSettingsDescription)
                    if !settings.meetingDetectionEnabled {
                        Text(L10n.enableMeetingNotificationsToChooseConditions)
                    }
                }
            }

            Section {
                Toggle(isOn: $settings.forceEchoCancellationForExternalMicrophone) {
                    Text(L10n.externalMicrophoneEchoCancellation)
                    Text(L10n.externalMicrophoneEchoCancellationDescription)
                }
                .toggleStyle(.switch)
                Text(L10n.builtInMicrophoneEchoCancellationDescription).foregroundStyle(.secondary)
            } header: {
                Text(L10n.audioInput)
                    .font(.dahliaSectionHeader)
            }

            Section {
                Toggle(isOn: $settings.hideLocalAccount) {
                    Text(L10n.hideLocalAccount)
                    Text(L10n.hideLocalAccountDescription)
                }
                .toggleStyle(.switch)
            } header: {
                Text(L10n.account)
                    .font(.dahliaSectionHeader)
            }

        }
        .formStyle(.grouped)
        .font(.dahliaBody)
    }
}
