import SwiftUI

/// 設定画面「一般」タブ。アカウント、録音、通知の基本設定を管理する。
struct GeneralSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var isLanguageSelectionPresented = false

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

            Section {
                LabeledContent(L10n.languageRange) {
                    Button(languageSelectionSummary) {
                        isLanguageSelectionPresented = true
                    }
                }
            } header: {
                Text(L10n.appLanguages)
            } footer: {
                Text(L10n.appLanguagesDescription)
            }

            Section(L10n.automaticRecordingStop) {
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
        .sheet(isPresented: $isLanguageSelectionPresented) {
            AppLanguageSelectionSheet(
                scope: settings.appLanguageScope,
                enabledLanguageIdentifiers: settings.enabledLanguageIdentifiers,
                onSave: saveLanguageSelection
            )
        }
    }

    private var languageSelectionSummary: String {
        guard settings.appLanguageScope == .selected else { return L10n.allSupportedLanguages }
        let summary = Self.languageSelectionSummaryParts(identifiers: settings.enabledLanguageIdentifiers)
        let names = summary.names.joined(separator: ", ")
        guard !names.isEmpty else { return L10n.languagesSelected(0) }
        guard summary.remainingCount > 0 else { return names }
        return "\(names), \(L10n.additionalLanguages(summary.remainingCount))"
    }

    static func languageSelectionSummaryParts(
        identifiers: Set<String>,
        locale: Locale = .current
    ) -> (names: [String], remainingCount: Int) {
        let names = identifiers
            .map { AppLanguageSelection(id: $0).displayName(locale: locale) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let displayedNames = Array(names.prefix(2))
        return (displayedNames, names.count - displayedNames.count)
    }

    private func saveLanguageSelection(
        scope: AppLanguageScope,
        enabledLanguageIdentifiers: Set<String>
    ) {
        settings.enabledLanguageIdentifiers = enabledLanguageIdentifiers
        settings.appLanguageScope = scope
    }
}
