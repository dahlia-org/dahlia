import SwiftUI

/// 設定画面「一般」タブ。表示言語と通知設定を管理する。
struct GeneralSettingsView: View {
    var sidebarViewModel: SidebarViewModel
    var onSelectVault: (VaultRecord) -> Void = { _ in }

    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        SettingsPage {
            SettingsSection(title: L10n.vault) {
                SettingsCard {
                    SettingsControlRow(
                        title: L10n.currentVault,
                        description: L10n.currentVaultDescription
                    ) {
                        HStack(spacing: 8) {
                            Menu(settings.currentVault?.name ?? L10n.noVaultSelected) {
                                ForEach(sidebarViewModel.allVaults) { vault in
                                    Button(vault.name) {
                                        onSelectVault(vault)
                                    }
                                }
                            }
                            .frame(maxWidth: 220)

                            Button(L10n.manageVaults) {
                                openWindow(id: WindowID.vaultManager)
                            }

                            Button(L10n.manageProjects) {
                                openWindow(id: WindowID.projectManager)
                            }
                        }
                    }
                }
            }

            SettingsSection(title: L10n.appearance) {
                SettingsCard {
                    SettingsControlRow(
                        title: L10n.appLanguage,
                        description: L10n.appLanguageDescription
                    ) {
                        Picker(L10n.appLanguage, selection: $settings.appLanguage) {
                            ForEach(AppLanguage.allCases) { language in
                                Text(language.displayName).tag(language)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 220)
                    }
                }
            }

            SettingsSection(
                title: L10n.notifications,
                description: L10n.notificationSettingsDescription
            ) {
                SettingsCard {
                    SettingsToggleRow(
                        title: L10n.meetingDetection,
                        description: L10n.meetingDetectionDescription,
                        isOn: $settings.meetingDetectionEnabled
                    )
                }
            }
        }
    }
}
