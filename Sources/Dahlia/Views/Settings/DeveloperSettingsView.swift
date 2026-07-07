import SwiftUI

/// 設定画面「開発者設定」タブ。外部サービス連携の開発者向け override を管理する。
struct DeveloperSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var clientSecretOverride = ""

    var body: some View {
        SettingsPage {
            SettingsSection(
                title: L10n.developerSettings,
                description: L10n.developerSettingsDescription
            ) {
                SettingsCard {
                    SettingsControlRow(
                        title: L10n.googleOAuthClientIDOverride,
                        description: L10n.googleOAuthClientIDOverrideDescription
                    ) {
                        TextField(
                            "",
                            text: $settings.googleOAuthClientIDOverride,
                            prompt: Text("1234567890-abcdef.apps.googleusercontent.com")
                        )
                        .font(.callout.monospaced())
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            saveClientIDOverride()
                        }
                    }

                    Divider()

                    SettingsControlRow(
                        title: L10n.googleOAuthClientSecretOverride,
                        description: L10n.googleOAuthClientSecretOverrideDescription
                    ) {
                        SecureField("", text: $clientSecretOverride)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit {
                                saveClientSecretOverride()
                            }
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 14) {
                        SettingsStatusMessage(
                            text: L10n.googleOAuthOverrideReconnectNotice,
                            systemImage: "info.circle",
                            tint: .blue
                        )

                        Button(L10n.resetToDefault) {
                            settings.googleOAuthClientIDOverride = ""
                            clientSecretOverride = ""
                            settings.googleOAuthClientSecretOverride = ""
                        }
                        .disabled(!hasOverrides)
                    }
                    .padding(20)
                }
            }
        }
        .task {
            clientSecretOverride = settings.googleOAuthClientSecretOverride
        }
        .onDisappear {
            saveOverrides()
        }
    }

    private var hasOverrides: Bool {
        !settings.googleOAuthClientIDOverride.isEmpty || !clientSecretOverride.isEmpty
    }

    private func saveOverrides() {
        saveClientIDOverride()
        saveClientSecretOverride()
    }

    private func saveClientIDOverride() {
        settings.googleOAuthClientIDOverride = settings.googleOAuthClientIDOverride.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func saveClientSecretOverride() {
        settings.googleOAuthClientSecretOverride = clientSecretOverride
        clientSecretOverride = settings.googleOAuthClientSecretOverride
    }
}
