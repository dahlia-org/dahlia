import SwiftUI

/// 設定画面「開発者設定」タブ。外部サービス連携の開発者向け override を管理する。
struct DeveloperSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var clientSecretOverride = ""

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading) {
                    Text(L10n.googleOAuthClientIDOverride)
                    Text(L10n.googleOAuthClientIDOverrideDescription)
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    TextField(
                        "",
                        text: $settings.googleOAuthClientIDOverride,
                        prompt: Text("1234567890-abcdef.apps.googleusercontent.com")
                    )
                    .font(.callout.monospaced())
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(Text(L10n.googleOAuthClientIDOverride))
                    .onSubmit {
                        saveClientIDOverride()
                    }
                }

                VStack(alignment: .leading) {
                    Text(L10n.googleOAuthClientSecretOverride)
                    Text(L10n.googleOAuthClientSecretOverrideDescription)
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    SecureField("", text: $clientSecretOverride)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel(Text(L10n.googleOAuthClientSecretOverride))
                        .onSubmit {
                            saveClientSecretOverride()
                        }
                }

                SettingsStatusMessage(
                    text: L10n.googleOAuthOverrideReconnectNotice,
                    systemImage: "info.circle",
                    tint: .blue
                )

                Button(L10n.restoreAppDefaults) {
                    resetOverrides()
                }
                .disabled(!hasOverrides)
            } header: {
                Text(L10n.developerSettings)
            } footer: {
                Text(L10n.developerSettingsDescription)
            }
        }
        .formStyle(.grouped)
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

    private func resetOverrides() {
        settings.googleOAuthClientIDOverride = ""
        clientSecretOverride = ""
        settings.googleOAuthClientSecretOverride = ""
    }
}
