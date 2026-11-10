import SwiftUI

/// Mac-wide language, notification, recording, and retention preferences. How the app looks is in `AppearanceSettingsView`.
struct GeneralSettingsView: View {
    private static let initialRetentionDays = 30
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
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

            Section(L10n.recordingStopDetection) {
                Toggle(isOn: $settings.automaticMeetingEndRecordingStopEnabled) {
                    Text(L10n.automaticMeetingEndRecordingStop)
                    Text(L10n.automaticMeetingEndRecordingStopDescription)
                }
                .toggleStyle(.switch)
            }

            Section(L10n.audioInput) {
                Toggle(isOn: $settings.forceEchoCancellationForExternalMicrophone) {
                    Text(L10n.externalMicrophoneEchoCancellation)
                    Text(L10n.externalMicrophoneEchoCancellationDescription)
                }
                .toggleStyle(.switch)
                Text(L10n.builtInMicrophoneEchoCancellationDescription).foregroundStyle(.secondary)
            }

            Section {
                Toggle(L10n.forever, isOn: Binding(
                    get: { settings.serverContentRetentionDays == 0 },
                    set: { settings.serverContentRetentionDays = $0 ? 0 : Self.initialRetentionDays }
                ))
                .toggleStyle(.switch)
                LabeledContent(L10n.serverContentRetentionDays) {
                    TextField(L10n.serverContentRetentionDays, value: Binding(
                        get: { settings.serverContentRetentionDays == 0 ? Self.initialRetentionDays : settings.serverContentRetentionDays },
                        set: { if $0 > 0 { settings.serverContentRetentionDays = $0 } }
                    ), format: .number.grouping(.never))
                        .disabled(settings.serverContentRetentionDays == 0)
                }
            } header: {
                Text(L10n.serverContentRetention)
            } footer: {
                Text(L10n.serverContentRetentionDescription)
            }
        }
        .formStyle(.grouped)
    }
}
