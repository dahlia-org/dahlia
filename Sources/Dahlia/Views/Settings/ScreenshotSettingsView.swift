import SwiftUI

/// 設定画面「スクリーンショット」タブ。自動スクリーンショット取得を管理する。
struct ScreenshotSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.automaticScreenshotEnabled) {
                    Text(L10n.automaticScreenshots)
                    Text(L10n.automaticScreenshotsToggleDescription)
                }
                .toggleStyle(.switch)

                Picker(selection: $settings.automaticScreenshotIntervalSeconds) {
                    ForEach(AppSettings.automaticScreenshotIntervalOptions, id: \.self) { interval in
                        Text(L10n.seconds(interval)).tag(interval)
                    }
                } label: {
                    Text(L10n.screenshotInterval)
                    Text(L10n.screenshotIntervalDescription)
                }
                .pickerStyle(.menu)
                .disabled(!settings.automaticScreenshotEnabled)

                Picker(selection: $settings.automaticScreenshotChangeThresholdPercent) {
                    ForEach(AppSettings.automaticScreenshotChangeThresholdPercentOptions, id: \.self) { threshold in
                        Text(L10n.percent(threshold)).tag(threshold)
                    }
                } label: {
                    Text(L10n.screenshotChangeThreshold)
                    Text(L10n.screenshotChangeThresholdDescription)
                }
                .pickerStyle(.menu)
                .disabled(!settings.automaticScreenshotEnabled)
            } header: {
                Text(L10n.automaticScreenshots)
            } footer: {
                Text(L10n.automaticScreenshotsDescription)
            }
        }
        .formStyle(.grouped)
    }
}
