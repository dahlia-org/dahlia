import SwiftUI

/// 設定画面「一般」タブ。アカウント、録音、通知の基本設定を管理する。
struct GeneralSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    Button(L10n.comingSoon) {}
                        .disabled(true)
                } label: {
                    Text(L10n.dahliaAccount)
                    Text(L10n.dahliaAccountDescription)
                }
            }

            Section(L10n.recording) {
                Toggle(isOn: $settings.automaticMeetingEndRecordingStopEnabled) {
                    Text(L10n.automaticMeetingEndRecordingStop)
                    Text(L10n.automaticMeetingEndRecordingStopDescription)
                }
                .toggleStyle(.switch)
            }

            Section {
                Toggle(isOn: $settings.meetingDetectionEnabled) {
                    Text(L10n.meetingNotifications)
                    Text(L10n.meetingNotificationsDescription)
                }
                .toggleStyle(.switch)

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
    }
}
