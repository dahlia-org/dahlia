import SwiftUI

/// 設定画面「一般」タブ。アカウント、録音、通知の基本設定を管理する。
struct GeneralSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var languages: [AppLanguageSelection] = []
    @State private var languageSearchText = ""
    @State private var isLoadingLanguages = true

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
                DahliaSegmentedPicker(
                    title: L10n.languageRange,
                    selection: $settings.appLanguageScope,
                    options: AppLanguageScope.allCases,
                    label: \.displayName
                )

                if settings.appLanguageScope == .selected {
                    TextField(L10n.searchLanguages, text: $languageSearchText)
                        .textFieldStyle(.roundedBorder)
                    if isLoadingLanguages {
                        ProgressView(L10n.loadingLanguages)
                    } else if filteredLanguages.isEmpty {
                        Text(L10n.noMatchingLanguages)
                            .foregroundStyle(DahliaDesign.secondaryTextColor)
                    } else {
                        ForEach(filteredLanguages) { language in
                            Toggle(isOn: languageBinding(language.id)) {
                                Text(language.displayName())
                                Text(language.id)
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                }
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
        .task {
            languages = await AppLanguageCatalog.load()
            isLoadingLanguages = false
        }
    }

    private var filteredLanguages: [AppLanguageSelection] {
        guard !languageSearchText.isEmpty else { return languages }
        return languages.filter {
            $0.id.localizedStandardContains(languageSearchText)
                || $0.displayName().localizedStandardContains(languageSearchText)
        }
    }

    private func languageBinding(_ identifier: String) -> Binding<Bool> {
        Binding {
            settings.enabledLanguageIdentifiers.contains(identifier)
        } set: { enabled in
            var identifiers = settings.enabledLanguageIdentifiers
            if enabled { identifiers.insert(identifier) } else { identifiers.remove(identifier) }
            settings.enabledLanguageIdentifiers = identifiers
        }
    }
}
