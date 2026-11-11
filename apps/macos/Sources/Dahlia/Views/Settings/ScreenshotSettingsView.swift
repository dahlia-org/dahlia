import SwiftUI

/// 設定画面「スクリーンショット」タブ。自動スクリーンショット取得を管理する。
struct ScreenshotSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.automaticScreenshotAdaptiveIntervalEnabled) {
                    Text(L10n.adaptiveScreenshotInterval)
                    Text(L10n.adaptiveScreenshotIntervalDescription)
                }
                .toggleStyle(.switch)

                Picker(selection: $settings.automaticScreenshotIntervalSeconds) {
                    ForEach(AppSettings.automaticScreenshotIntervalOptions, id: \.self) { interval in
                        Text(L10n.seconds(interval)).font(.dahliaBody).tag(interval)
                    }
                } label: {
                    Text(L10n.screenshotInterval)
                    Text(settings.automaticScreenshotAdaptiveIntervalEnabled
                        ? L10n.adaptiveScreenshotIntervalFallbackDescription
                        : L10n.fixedScreenshotIntervalDescription)
                }
                .pickerStyle(.menu)

                Picker(selection: $settings.automaticScreenshotChangeThresholdPercent) {
                    ForEach(AppSettings.automaticScreenshotChangeThresholdPercentOptions, id: \.self) { threshold in
                        Text(L10n.percent(threshold)).font(.dahliaBody).tag(threshold)
                    }
                } label: {
                    Text(L10n.screenshotChangeThreshold)
                    Text(settings.automaticScreenshotAdaptiveIntervalEnabled
                        ? L10n.adaptiveScreenshotChangeThresholdDescription
                        : L10n.fixedScreenshotChangeThresholdDescription)
                }
                .pickerStyle(.menu)
            } header: {
                Text(L10n.automaticScreenshots)
                    .font(.dahliaSectionHeader)
            } footer: {
                Text(L10n.automaticScreenshotsDescription)
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
                    .font(.dahliaSectionHeader)
            } footer: {
                Text(L10n.sharedContentDetectionFallbackDescription)
            }

        }
        .formStyle(.grouped)
        .font(.dahliaBody)
    }
}
