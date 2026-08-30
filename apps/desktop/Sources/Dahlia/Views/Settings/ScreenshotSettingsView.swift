import SwiftUI

/// 設定画面「スクリーンショット」タブ。自動スクリーンショット取得を管理する。
struct ScreenshotSettingsView: View {
    let onOpenLanguageSettings: () -> Void
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
                VStack(alignment: .leading) {
                    Text(L10n.automaticScreenshotsDescription)
                    if !settings.automaticScreenshotEnabled {
                        Text(L10n.enableAutomaticScreenshotsToConfigure)
                    }
                }
            }

            Section {
                Toggle(isOn: $settings.automaticScreenshotDetectChangesInSharedRegionOnly) {
                    Text(L10n.detectScreenshotChangesInSharedContentOnly)
                    Text(L10n.sharedContentChangeDetectionDescription)
                }
                .toggleStyle(.switch)

                Toggle(isOn: $settings.automaticScreenshotCropToSharedRegion) {
                    Text(L10n.saveSharedContentOnly)
                    Text(L10n.saveSharedContentOnlyDescription)
                }
                .toggleStyle(.switch)
            } header: {
                Text(L10n.sharedContent)
            } footer: {
                Text(L10n.sharedContentDetectionFallbackDescription)
            }
            .disabled(!settings.automaticScreenshotEnabled)

            Section {
                LabeledContent {
                    Button(L10n.openLanguageSettings, action: onOpenLanguageSettings)
                } label: {
                    Text(L10n.imageTextLanguages)
                    Text(L10n.imageTextLanguagesDescription)
                }
            }
        }
        .formStyle(.grouped)
    }
}
