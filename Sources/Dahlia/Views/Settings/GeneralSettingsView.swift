import SwiftUI

/// 設定画面「一般」タブ。表示言語と通知設定を管理する。
struct GeneralSettingsView: View {
    var sidebarViewModel: SidebarViewModel
    var onSelectVault: (VaultRecord) -> Void = { _ in }

    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section(L10n.vault) {
                LabeledContent {
                    Menu(settings.currentVault?.name ?? L10n.noVaultSelected) {
                        ForEach(sidebarViewModel.allVaults) { vault in
                            Button(vault.name) {
                                onSelectVault(vault)
                            }
                        }
                    }
                } label: {
                    Text(L10n.currentVault)
                    Text(L10n.currentVaultDescription)
                }

                Button(L10n.manageVaults) {
                    openWindow(id: WindowID.vaultManager)
                }

                Button(L10n.manageProjects) {
                    openWindow(id: WindowID.projectManager)
                }
            }

            Section(L10n.appearance) {
                Picker(selection: $settings.appLanguage) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                } label: {
                    Text(L10n.appLanguage)
                    Text(L10n.appLanguageDescription)
                }
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
                Text(L10n.notificationSettingsDescription)
            }
        }
        .formStyle(.grouped)
    }
}
